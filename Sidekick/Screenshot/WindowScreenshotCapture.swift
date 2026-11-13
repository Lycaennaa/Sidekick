import AppKit
import CoreGraphics
import ScreenCaptureKit

@MainActor
private final class WindowScreenshotCaptureSession {
    private var captureWindowsByID: [CGWindowID: SCWindow]

    init() {
        captureWindowsByID = [:]
    }

    init(captureWindowsByID: sending [CGWindowID: SCWindow]) {
        self.captureWindowsByID = captureWindowsByID
    }

    func retainWindows(withIDs windowIDs: Set<CGWindowID>) {
        captureWindowsByID = captureWindowsByID.filter { windowIDs.contains($0.key) }
    }

    func capture(windowID: CGWindowID, showsCursor: Bool) async throws -> CGImage {
        guard let window = captureWindowsByID[windowID] else {
            throw WindowCaptureError.windowUnavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.captureResolution = .best
        configuration.showsCursor = showsCursor
        configuration.ignoreShadowsSingleWindow = true
        let scale = captureScale(for: window.frame)
        let outputWidth = (window.frame.width * scale).rounded()
        let outputHeight = (window.frame.height * scale).rounded()
        guard outputWidth.isFinite, outputHeight.isFinite,
              outputWidth >= 1, outputHeight >= 1,
              outputWidth < CGFloat(Int.max), outputHeight < CGFloat(Int.max) else {
            throw WindowCaptureError.captureFailed
        }
        configuration.width = Int(outputWidth)
        configuration.height = Int(outputHeight)
        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration,
                completionHandler: { image, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: WindowCaptureError.captureFailed)
                    }
                }
            )
        }
    }

    private func captureScale(for windowFrame: CGRect) -> CGFloat {
        NSScreen.screens.compactMap { screen -> CGFloat? in
            guard let displayID = screen.screenshotDisplayID else { return nil }
            let displayBounds = CGDisplayBounds(displayID)
            return displayBounds.intersects(windowFrame) ? screen.backingScaleFactor : nil
        }.max() ?? 1
    }
}

@MainActor
struct WindowScreenshotInventory {
    let windows: [ScreenshotWindow]
    fileprivate let captureSession: WindowScreenshotCaptureSession

    init() {
        windows = []
        captureSession = WindowScreenshotCaptureSession()
    }

    fileprivate init(windows: [ScreenshotWindow], captureSession: WindowScreenshotCaptureSession) {
        self.windows = windows
        self.captureSession = captureSession
    }
}

enum WindowScreenshotCapture {
    private static let ignoredSystemBundleIDs = ScreenshotWindowCandidate.ignoredSystemBundleIDs

    private struct DisplayGeometry {
        let quartzBounds: CGRect
        let screenFrame: CGRect
    }

    @MainActor
    static func windows() async throws -> WindowScreenshotInventory {
        let snapshot = try await captureSnapshot()
        let displays = displayGeometries()
        let selectableWindows = selectableScreenCaptureWindows(in: snapshot.windows)
        let selectableIDs = Set(selectableWindows.map(\.id))
        let occlusionWindows = occlusionWindowsFromCoreGraphics(snapshot.windows)
        let visibleRegionsByWindowID = occlusionWindows.map {
            ScreenshotWindowVisibility.visibleRegionsByWindowID(
                frontToBack: $0,
                selectableIDs: selectableIDs,
                displayBounds: displays.map(\.quartzBounds)
            )
        }
        let visibleWindowOrder: [CGWindowID]? = occlusionWindows.map { windows in
            windows.filter { visibleRegionsByWindowID?[$0.id] != nil }.map(\.id)
        }
        let candidates = selectableWindows.flatMap { window in
            let visibleRegions = visibleRegionsByWindowID.map { $0[window.id] ?? [] }
            return makeScreenshotWindows(
                from: window,
                visibleQuartzRegions: visibleRegions,
                displays: displays
            )
        }
        let candidateOrder = ScreenshotWindowVisibility.orderedCandidateIDs(
            candidateIDs: selectableWindows.map(\.id),
            frontToBackWindowIDs: visibleWindowOrder
        )
        let visibleCandidateIDs = Set(candidateOrder)
        let rankByWindowID = Dictionary(
            uniqueKeysWithValues: candidateOrder.enumerated().map { ($0.element, $0.offset) }
        )
        let visibleWindows = candidates
            .filter { visibleCandidateIDs.contains($0.id) }
            .sorted {
                rankByWindowID[$0.id, default: .max] < rankByWindowID[$1.id, default: .max]
            }
        snapshot.captureSession.retainWindows(withIDs: visibleCandidateIDs)
        return WindowScreenshotInventory(
            windows: visibleWindows,
            captureSession: snapshot.captureSession
        )
    }

    private nonisolated static func captureSnapshot() async throws -> (
        windows: [ScreenshotWindowDescriptor],
        captureSession: WindowScreenshotCaptureSession
    ) {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let shareableWindows = content.windows
        let descriptors = shareableWindows.map { window in
            let owningApplication = window.owningApplication
            return ScreenshotWindowDescriptor(
                id: window.windowID,
                title: window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                applicationName: owningApplication?.applicationName ?? "",
                frame: window.frame,
                bundleIdentifier: owningApplication?.bundleIdentifier,
                isOnScreen: window.isOnScreen,
                hasOwningApplication: owningApplication != nil,
                windowLayer: window.windowLayer
            )
        }
        let captureWindowsByID = Dictionary(
            uniqueKeysWithValues: shareableWindows.map { ($0.windowID, $0) }
        )
        let captureSession = await WindowScreenshotCaptureSession(
            captureWindowsByID: captureWindowsByID
        )
        return (descriptors, captureSession)
    }

    private static func selectableScreenCaptureWindows(
        in windows: [ScreenshotWindowDescriptor]
    ) -> [ScreenshotWindowDescriptor] {
        windows.filter { window in
            let bundleID = window.bundleIdentifier
            return ScreenshotWindowCandidate(
                frame: window.frame,
                isOnScreen: window.isOnScreen,
                title: window.title,
                appName: window.applicationName,
                bundleID: bundleID,
                hasOwningApplication: window.hasOwningApplication,
                windowLayer: window.windowLayer,
                isOwnAppWindow: bundleID == Bundle.main.bundleIdentifier
            ).isSelectable
        }
    }

    private static func displayGeometries() -> [DisplayGeometry] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            return DisplayGeometry(
                quartzBounds: CGDisplayBounds(CGDirectDisplayID(number.uint32Value)),
                screenFrame: screen.frame
            )
        }
    }

    private static func makeScreenshotWindows(
        from window: ScreenshotWindowDescriptor,
        visibleQuartzRegions: [CGRect]?,
        displays: [DisplayGeometry]
    ) -> [ScreenshotWindow] {
        displays.compactMap { display in
            ScreenshotWindow.onDisplay(
                window,
                displayBounds: display.quartzBounds,
                screenFrame: display.screenFrame,
                visibleQuartzRegions: visibleQuartzRegions
            )
        }
    }

    private static func occlusionWindowsFromCoreGraphics(
        _ shareableWindows: [ScreenshotWindowDescriptor]
    ) -> [ScreenshotWindowOcclusion]? {
        var bundleIDs: [CGWindowID: String] = [:]
        var expectedIDs = Set<CGWindowID>()
        bundleIDs.reserveCapacity(shareableWindows.count)
        expectedIDs.reserveCapacity(shareableWindows.count)
        for window in shareableWindows {
            let bundleID = window.bundleIdentifier
            if let bundleID, ignoredSystemBundleIDs.contains(bundleID) { continue }
            expectedIDs.insert(window.id)
            if let bundleID { bundleIDs[window.id] = bundleID }
        }
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        guard let windowInfo else { return nil }
        let occlusionWindows = windowInfo.compactMap { info -> ScreenshotWindowOcclusion? in
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
            let id = CGWindowID(number.uint32Value)
            guard expectedIDs.contains(id) else { return nil }
            return occlusionWindow(from: info, bundleIdentifier: bundleIDs[id])
        }
        return occlusionWindows
    }

    static func occlusionWindow(
        from info: [String: Any],
        bundleIdentifier: String?
    ) -> ScreenshotWindowOcclusion? {
        // Transparent picker panels still have a Core Graphics window alpha of 1.
        // They intercept input, but must never hide the application windows beneath them.
        let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue
        if ownerPID == ProcessInfo.processInfo.processIdentifier,
           layer == Int(CGWindowLevelForKey(.screenSaverWindow)) {
            return nil
        }
        guard let number = info[kCGWindowNumber as String] as? NSNumber,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              let alpha = info[kCGWindowAlpha as String] as? NSNumber else {
            return nil
        }
        return ScreenshotWindowOcclusion(
            id: CGWindowID(number.uint32Value),
            frame: frame,
            alpha: CGFloat(alpha.doubleValue),
            bundleIdentifier: bundleIdentifier,
            windowLayer: layer ?? Int(CGWindowLevelForKey(.normalWindow))
        )
    }

    @MainActor
    static func capture(
        windowID: CGWindowID,
        from inventory: WindowScreenshotInventory,
        showsCursor: Bool
    ) async throws -> CGImage {
        try await inventory.captureSession.capture(
            windowID: windowID,
            showsCursor: showsCursor
        )
    }
}

enum WindowCaptureError: Error {
    case windowUnavailable
    case captureFailed
}

@MainActor
enum WindowScreenshotSelection {
    private struct Surface {
        let screenFrame: CGRect
        let panel: WindowScreenshotSelectionPanel
        let view: WindowScreenshotSelectionView
    }

    @MainActor
    final class Session {
        private let choices: AsyncStream<CGWindowID?>
        private let continuation: AsyncStream<CGWindowID?>.Continuation
        private var surfaces: [Surface] = []
        private var isClosed = false
        private(set) var isCancelled = false

        init() {
            let (choices, continuation) = AsyncStream<CGWindowID?>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            self.choices = choices
            self.continuation = continuation
            let surfaces = NSScreen.screens.map { screen -> Surface in
                let screenFrame = screen.frame
                let panel = WindowScreenshotSelectionPanel(
                    contentRect: screenFrame,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                panel.level = .screenSaver
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.acceptsMouseMovedEvents = true
                let view = WindowScreenshotSelectionView(
                    frame: NSRect(origin: .zero, size: screenFrame.size),
                    windows: []
                )
                view.onSelect = { continuation.yield($0) }
                panel.contentView = view
                panel.orderFrontRegardless()
                return Surface(screenFrame: screenFrame, panel: panel, view: view)
            }
            self.surfaces = surfaces

            surfaces.forEach { surface in
                surface.view.onCancel = { [weak self] in self?.cancel() }
            }
            NSApp.activate(ignoringOtherApps: true)
            surfaces.first?.panel.makeKeyAndOrderFront(nil)
        }

        func update(windows: [ScreenshotWindow]) {
            let windowsByScreen = Dictionary(grouping: windows, by: \.screenFrame)
            for surface in surfaces {
                surface.view.updateWindows(windowsByScreen[surface.screenFrame] ?? [], searching: false)
            }
        }

        func waitForSelection() async -> CGWindowID? {
            await withTaskCancellationHandler {
                for await choice in choices { return choice }
                return nil
            } onCancel: {
                continuation.yield(nil)
            }
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            continuation.finish()
            surfaces.forEach { surface in
                surface.view.onSelect = nil
                surface.view.onCancel = nil
                surface.panel.orderOut(nil)
            }
        }

        private func cancel() {
            guard !isClosed else { return }
            isCancelled = true
            continuation.yield(nil)
            close()
        }
    }
}

@MainActor
private final class WindowScreenshotSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
@MainActor
private final class WindowScreenshotSelectionView: NSView {
    var windows: [ScreenshotWindow]
    var onSelect: ((CGWindowID) -> Void)?
    var onCancel: (() -> Void)?
    private var hoveredID: CGWindowID?
    private var isSearchingForWindows = true

    init(frame: NSRect, windows: [ScreenshotWindow]) {
        self.windows = windows
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { nil }

    func updateWindows(_ windows: [ScreenshotWindow], searching: Bool) {
        self.windows = windows
        isSearchingForWindows = searching
        hoveredID = nil
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
        if let hoveredID {
            onSelect?(hoveredID)
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        let instruction = (isSearchingForWindows
            ? "Looking for capturable windows… • Escape or click to cancel"
            : "Click a window to capture • Click elsewhere to cancel") as NSString
        let instructionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let instructionSize = instruction.size(withAttributes: instructionAttributes)
        instruction.draw(
            at: CGPoint(x: (bounds.width - instructionSize.width) / 2, y: bounds.maxY - instructionSize.height - 24),
            withAttributes: instructionAttributes
        )
        guard let hovered = windows.first(where: { $0.id == hoveredID }) else { return }
        let rect = hovered.selectionFrame
        let accent = NSColor.controlAccentColor
        accent.withAlphaComponent(0.25).setFill()
        rect.fill()
        accent.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 2
        border.stroke()
        let label = "\(hovered.applicationName) — \(hovered.title)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let labelHeight = min(26, rect.height)
        let labelRect = CGRect(
            x: rect.minX,
            y: rect.maxY - labelHeight,
            width: max(1, rect.width),
            height: labelHeight
        )
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 5, yRadius: 5).fill()
        label.draw(
            with: labelRect.insetBy(dx: 8, dy: 4),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes,
            context: nil
        )
    }

    private func updateHover(at point: CGPoint) {
        let found = ScreenshotWindowHitTesting.frontmostWindowID(at: point, windows: windows)
        guard found != hoveredID else { return }
        hoveredID = found
        needsDisplay = true
    }
}
