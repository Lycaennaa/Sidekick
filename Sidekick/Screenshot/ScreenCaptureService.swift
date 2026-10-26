import AppKit
import ScreenCaptureKit

enum ActiveDisplayScreenshotError: Error {
    case activeDisplayUnavailable
    case displayUnavailable
}

struct CapturedDisplayScreenshot {
    let image: CGImage
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
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
    static func shouldExcludeDisplayOverlay(
        windowLayer: Int,
        normalWindowLayer: Int,
        windowFrame: CGRect,
        displayFrame: CGRect
    ) -> Bool {
        windowLayer > normalWindowLayer && windowFrame.contains(displayFrame)
    }

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

        let normalWindowLayer = Int(CGWindowLevelForKey(.normalWindow))
        let displayBounds = CGDisplayBounds(displayID)
        let excludedOverlayWindows = content.windows.filter { window in
            Self.shouldExcludeDisplayOverlay(
                windowLayer: window.windowLayer,
                normalWindowLayer: normalWindowLayer,
                windowFrame: window.frame,
                displayFrame: displayBounds
            )
        }
        let filter = SCContentFilter(display: display, excludingWindows: excludedOverlayWindows)
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
            screenFrame: screenFrame
        )
    }
}
