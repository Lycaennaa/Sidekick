import AppKit
import CoreGraphics
import ScreenCaptureKit

enum WindowScreenshotCapture {
    private static let ignoredSystemBundleIDs = ScreenshotWindowCandidate.ignoredSystemBundleIDs

    static func windows() async throws -> [ScreenshotWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        let selectableWindows = content.windows.filter { window in
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
        let selectableIDs = Set(selectableWindows.map(\.windowID))
        let occlusionWindows = occlusionWindowsFromCoreGraphics(
            content.windows,
            selectableWindows: selectableWindows
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
        let candidates = selectableWindows.flatMap { window in
            let visibleRegions = visibleRegionsByWindowID.map { $0[window.windowID] ?? [] }
            return makeScreenshotWindows(from: window, visibleQuartzRegions: visibleRegions)
        }
        let candidateOrder = ScreenshotWindowVisibility.orderedCandidateIDs(
            candidateIDs: selectableWindows.map(\.windowID),
            frontToBackWindowIDs: visibleWindowOrder
        )
        let visibleCandidateIDs = Set(candidateOrder)
        let rankByWindowID = Dictionary(
            uniqueKeysWithValues: candidateOrder.enumerated().map { ($0.element, $0.offset) }
        )
        return candidates
            .filter { visibleCandidateIDs.contains($0.id) }
            .sorted {
                rankByWindowID[$0.id, default: .max] < rankByWindowID[$1.id, default: .max]
            }
    }

    private static func makeScreenshotWindows(
        from window: SCWindow,
        visibleQuartzRegions: [CGRect]?
    ) -> [ScreenshotWindow] {
        let appName = window.owningApplication?.applicationName ?? ""
        let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let descriptor = ScreenshotWindowDescriptor(
            id: window.windowID,
            title: title.isEmpty ? appName : title,
            applicationName: appName,
            frame: window.frame
        )
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            let displayBounds = CGDisplayBounds(CGDirectDisplayID(number.uint32Value))
            return ScreenshotWindow.onDisplay(
                descriptor,
                displayBounds: displayBounds,
                screenFrame: screen.frame,
                visibleQuartzRegions: visibleQuartzRegions
            )
        }
    }

    private static func occlusionWindowsFromCoreGraphics(
        _ shareableWindows: [SCWindow],
        selectableWindows: [SCWindow]
    ) -> [ScreenshotWindowOcclusion]? {
        let bundleIDs: [CGWindowID: String] = Dictionary(
            uniqueKeysWithValues: shareableWindows.compactMap { window -> (CGWindowID, String)? in
                guard let bundleIdentifier = window.owningApplication?.bundleIdentifier else {
                    return nil
                }
                return (window.windowID, bundleIdentifier)
            }
        )
        let selectableIDs = Set(selectableWindows.map(\.windowID))
        let ignoredIDs = Set(shareableWindows.compactMap { window -> CGWindowID? in
            guard let bundleIdentifier = window.owningApplication?.bundleIdentifier,
                  ignoredSystemBundleIDs.contains(bundleIdentifier) else {
                return nil
            }
            return window.windowID
        })
        let expectedIDs = Set(shareableWindows.map(\.windowID)).subtracting(ignoredIDs)
        guard !selectableIDs.isEmpty, selectableIDs.isSubset(of: expectedIDs) else { return nil }
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let occlusionWindows = windowInfo.compactMap { info -> ScreenshotWindowOcclusion? in
            guard let number = info[kCGWindowNumber as String] as? NSNumber else { return nil }
            let id = CGWindowID(number.uint32Value)
            guard expectedIDs.contains(id),
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let alpha = info[kCGWindowAlpha as String] as? NSNumber else {
                return nil
            }
            return ScreenshotWindowOcclusion(
                id: id,
                frame: frame,
                alpha: CGFloat(alpha.doubleValue),
                bundleIdentifier: bundleIDs[id]
            )
        }
        let enumeratedIDs = Set(occlusionWindows.map(\.id))
        guard selectableIDs.isSubset(of: enumeratedIDs) else { return nil }
        return occlusionWindows
    }

    static func capture(windowID: CGWindowID, showsCursor: Bool) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
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
