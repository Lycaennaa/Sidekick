import AppKit
import CoreGraphics
import ScreenCaptureKit

struct WindowScreenshotInventory {
    let windows: [ScreenshotWindow]
    fileprivate let captureWindowsByID: [CGWindowID: SCWindow]
}

enum WindowScreenshotCapture {
    private static let ignoredSystemBundleIDs = ScreenshotWindowCandidate.ignoredSystemBundleIDs

    private struct DisplayGeometry {
        let quartzBounds: CGRect
        let screenFrame: CGRect
    }

    static func windows() async throws -> WindowScreenshotInventory {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let selectableWindows = selectableScreenCaptureWindows(in: content.windows)
        let selectableIDs = Set(selectableWindows.map(\.windowID))
        let occlusionWindows = occlusionWindowsFromCoreGraphics(
            content.windows,
            selectableIDs: selectableIDs
        )
        let visibleRegionsByWindowID = occlusionWindows.map {
            ScreenshotWindowVisibility.visibleRegionsByWindowID(
                frontToBack: $0,
                selectableIDs: selectableIDs
            )
        }
        let visibleWindowOrder: [CGWindowID]? = occlusionWindows.map { windows in
            windows.filter { visibleRegionsByWindowID?[$0.id] != nil }.map(\.id)
        }
        let displays = displayGeometries()
        let candidates = selectableWindows.flatMap { window in
            let visibleRegions = visibleRegionsByWindowID.map { $0[window.windowID] ?? [] }
            return makeScreenshotWindows(
                from: window,
                visibleQuartzRegions: visibleRegions,
                displays: displays
            )
        }
        let candidateOrder = ScreenshotWindowVisibility.orderedCandidateIDs(
            candidateIDs: selectableWindows.map(\.windowID),
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
        let captureWindowsByID = Dictionary(
            uniqueKeysWithValues: selectableWindows
                .filter { visibleCandidateIDs.contains($0.windowID) }
                .map { ($0.windowID, $0) }
        )
        return WindowScreenshotInventory(
            windows: visibleWindows,
            captureWindowsByID: captureWindowsByID
        )
    }

    private static func selectableScreenCaptureWindows(in windows: [SCWindow]) -> [SCWindow] {
        windows.filter { window in
            let appName = window.owningApplication?.applicationName ?? ""
            let bundleID = window.owningApplication?.bundleIdentifier
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ScreenshotWindowCandidate(
                frame: window.frame,
                isOnScreen: window.isOnScreen,
                title: title,
                appName: appName,
                bundleID: bundleID,
                hasOwningApplication: window.owningApplication != nil,
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
        from window: SCWindow,
        visibleQuartzRegions: [CGRect]?,
        displays: [DisplayGeometry]
    ) -> [ScreenshotWindow] {
        let appName = window.owningApplication?.applicationName ?? ""
        let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let descriptor = ScreenshotWindowDescriptor(
            id: window.windowID,
            title: title.isEmpty ? appName : title,
            applicationName: appName,
            frame: window.frame
        )
        return displays.compactMap { display in
            ScreenshotWindow.onDisplay(
                descriptor,
                displayBounds: display.quartzBounds,
                screenFrame: display.screenFrame,
                visibleQuartzRegions: visibleQuartzRegions
            )
        }
    }

    private static func occlusionWindowsFromCoreGraphics(
        _ shareableWindows: [SCWindow],
        selectableIDs: Set<CGWindowID>
    ) -> [ScreenshotWindowOcclusion]? {
        var bundleIDs: [CGWindowID: String] = [:]
        var expectedIDs = Set<CGWindowID>()
        bundleIDs.reserveCapacity(shareableWindows.count)
        expectedIDs.reserveCapacity(shareableWindows.count)
        for window in shareableWindows {
            let bundleID = window.owningApplication?.bundleIdentifier
            if let bundleID, ignoredSystemBundleIDs.contains(bundleID) { continue }
            expectedIDs.insert(window.windowID)
            if let bundleID { bundleIDs[window.windowID] = bundleID }
        }
        guard !selectableIDs.isEmpty, selectableIDs.isSubset(of: expectedIDs) else { return nil }
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        var enumeratedSelectableIDs = Set<CGWindowID>()
        enumeratedSelectableIDs.reserveCapacity(selectableIDs.count)
        let occlusionWindows = windowInfo.compactMap { info -> ScreenshotWindowOcclusion? in
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
            let id = CGWindowID(number.uint32Value)
            guard expectedIDs.contains(id),
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let alpha = info[kCGWindowAlpha as String] as? NSNumber else {
                return nil
            }
            if selectableIDs.contains(id) {
                enumeratedSelectableIDs.insert(id)
            }
            return ScreenshotWindowOcclusion(
                id: id,
                frame: frame,
                alpha: CGFloat(alpha.doubleValue),
                bundleIdentifier: bundleIDs[id]
            )
        }
        guard selectableIDs.isSubset(of: enumeratedSelectableIDs) else { return nil }
        return occlusionWindows
    }

    static func capture(
        windowID: CGWindowID,
        from inventory: WindowScreenshotInventory,
        showsCursor: Bool
    ) async throws -> CGImage {
        guard let window = inventory.captureWindowsByID[windowID] else {
            throw WindowCaptureError.windowUnavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.captureResolution = .best
        configuration.showsCursor = showsCursor
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }
}

enum WindowCaptureError: Error {
    case windowUnavailable
}

@MainActor
enum WindowScreenshotSelection {
    static func choose(from windows: [ScreenshotWindow]) async -> CGWindowID? {
        guard !windows.isEmpty else { return nil }
        let (choices, continuation) = AsyncStream<CGWindowID?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let grouped = Dictionary(grouping: windows, by: \.screenFrame)
        let panels = NSScreen.screens.map { screen -> WindowScreenshotSelectionPanel in
            let screenFrame = screen.frame
            let screenWindows = grouped[screenFrame] ?? []
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
                windows: screenWindows
            )
            view.onSelect = { continuation.yield($0) }
            view.onCancel = { continuation.yield(nil) }
            panel.contentView = view
            panel.orderFrontRegardless()
            return panel
        }
        NSApp.activate(ignoringOtherApps: true)
        panels.first?.makeKeyAndOrderFront(nil)
        defer {
            continuation.finish()
            panels.forEach { $0.orderOut(nil) }
        }
        let selection = await withTaskCancellationHandler {
            for await choice in choices { return choice }
            return nil
        } onCancel: {
            continuation.yield(nil)
        }
        return selection
    }
}

@MainActor
private final class WindowScreenshotSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
@MainActor
private final class WindowScreenshotSelectionView: NSView {
    let windows: [ScreenshotWindow]
    var onSelect: ((CGWindowID) -> Void)?
    var onCancel: (() -> Void)?
    private var hoveredID: CGWindowID?

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
        let instruction = "Click a window to capture • Click elsewhere to cancel" as NSString
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
