import AppKit
import ScreenCaptureKit

enum ActiveDisplayScreenshotError: Error {
    case activeDisplayUnavailable
    case displayUnavailable
    case windowUnavailable
}

struct CapturedDisplayScreenshot {
    let image: CGImage
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let windowTargets: [ScreenshotWindowTarget]?

    init(
        image: CGImage,
        displayID: CGDirectDisplayID,
        screenFrame: CGRect,
        windowTargets: [ScreenshotWindowTarget]? = nil
    ) {
        self.image = image
        self.displayID = displayID
        self.screenFrame = screenFrame
        self.windowTargets = windowTargets
    }
}

struct ScreenshotWindowSnapshot {
    let windowID: CGWindowID
    let bounds: CGRect
    let layer: Int
    let alpha: CGFloat
    let window: SCWindow?

    init(
        windowID: CGWindowID,
        bounds: CGRect,
        layer: Int,
        alpha: CGFloat,
        window: SCWindow? = nil
    ) {
        self.windowID = windowID
        self.bounds = bounds
        self.layer = layer
        self.alpha = alpha
        self.window = window
    }
}

struct ScreenshotWindowTarget: Equatable {
    let windowID: CGWindowID
    let bounds: CGRect
    let layer: Int
    let window: SCWindow?
    var isCapturable: Bool { window != nil }
    var isSelectable: Bool { layer == 0 && isCapturable }

    init(windowID: CGWindowID, bounds: CGRect, layer: Int, window: SCWindow? = nil) {
        self.windowID = windowID
        self.bounds = bounds
        self.layer = layer
        self.window = window
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.windowID == rhs.windowID && lhs.bounds == rhs.bounds &&
            lhs.layer == rhs.layer && lhs.isCapturable == rhs.isCapturable
    }
}

typealias ScreenshotWindowCapture = @MainActor (ScreenshotWindowTarget, Bool) async throws -> CGImage

enum ScreenshotWindowTargeting {
    enum Selection: Equatable {
        case none
        case unavailable(ScreenshotWindowTarget)
        case selected(ScreenshotWindowTarget)
    }

    static func snapshots(
        from windowInfo: CFArray?,
        shareableWindows: [CGWindowID: SCWindow]
    ) -> [ScreenshotWindowSnapshot]? {
        guard let windowInfo, let windows = windowInfo as? [[String: Any]] else { return nil }
        return windows.compactMap { info in
            guard info[kCGWindowIsOnscreen as String] as? Bool == true,
                  let number = info[kCGWindowNumber as String] as? NSNumber,
                  let layer = info[kCGWindowLayer as String] as? NSNumber,
                  let boundsDictionary = info[kCGWindowBounds as String] as? [String: Any] else {
                return nil
            }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDictionary as CFDictionary, &bounds) else { return nil }
            let windowID = CGWindowID(number.uint32Value)
            let window = shareableWindows[windowID]
            return ScreenshotWindowSnapshot(
                windowID: windowID,
                bounds: bounds,
                layer: layer.intValue,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1,
                window: window
            )
        }
    }

    static func targets(
        from snapshots: [ScreenshotWindowSnapshot]?,
        displayBounds: CGRect,
        screenSize: CGSize
    ) -> [ScreenshotWindowTarget]? {
        guard let snapshots else { return nil }
        guard displayBounds.width > 0, displayBounds.height > 0,
              screenSize.width > 0, screenSize.height > 0 else { return [] }

        let scaleX = screenSize.width / displayBounds.width
        let scaleY = screenSize.height / displayBounds.height
        func visibleBounds(_ bounds: CGRect) -> CGRect? {
            let clipped = bounds.intersection(displayBounds)
            guard !clipped.isNull, !clipped.isEmpty else { return nil }
            return CGRect(
                x: (clipped.minX - displayBounds.minX) * scaleX,
                y: (displayBounds.maxY - clipped.maxY) * scaleY,
                width: clipped.width * scaleX,
                height: clipped.height * scaleY
            )
        }

        return snapshots.compactMap { snapshot in
            guard snapshot.layer >= 0, snapshot.alpha > 0,
                  let bounds = visibleBounds(snapshot.bounds) else { return nil }
            return ScreenshotWindowTarget(
                windowID: snapshot.windowID,
                bounds: bounds,
                layer: snapshot.layer,
                window: snapshot.window
            )
        }
    }

    static func selection(at point: CGPoint, from targets: [ScreenshotWindowTarget]) -> Selection {
        guard let target = targets.first(where: { $0.bounds.contains(point) }) else { return .none }
        guard target.isSelectable else { return .unavailable(target) }
        return .selected(target)
    }
}

extension NSScreen {
    var screenshotDisplayID: CGDirectDisplayID? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}

@MainActor
enum ActiveDisplayScreenshotCapture {
    static func capture(showsCursor: Bool = false) async throws -> CapturedDisplayScreenshot {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }),
              let displayID = screen.screenshotDisplayID else {
            throw ActiveDisplayScreenshotError.activeDisplayUnavailable
        }
        let screenFrame = screen.frame

        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ActiveDisplayScreenshotError.displayUnavailable
        }
        let shareableWindows = Dictionary(uniqueKeysWithValues: content.windows.map {
            ($0.windowID, $0)
        })
        let windowSnapshots = ScreenshotWindowTargeting.snapshots(
            from: CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID),
            shareableWindows: shareableWindows
        )
        let windowTargets = ScreenshotWindowTargeting.targets(
            from: windowSnapshots,
            displayBounds: CGDisplayBounds(displayID),
            screenSize: screenFrame.size
        )

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.captureDynamicRange = .SDR
        configuration.showsCursor = showsCursor

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return CapturedDisplayScreenshot(
            image: image,
            displayID: displayID,
            screenFrame: screenFrame,
            windowTargets: windowTargets
        )
    }
    static func captureWindow(_ target: ScreenshotWindowTarget, showsCursor: Bool) async throws -> CGImage {
        guard let window = target.window else { throw ActiveDisplayScreenshotError.windowUnavailable }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded()))
        configuration.height = max(1, Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded()))
        configuration.captureDynamicRange = .SDR
        configuration.showsCursor = showsCursor
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
