import AppKit
import XCTest

@MainActor
final class WindowScreenshotCaptureOcclusionTests: XCTestCase {
    func testOccludedCaptureKeepsWholeWindowAndExcludesDisplayArea() async throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No active display is available")
        }
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is required for this integration test")
        }

        let title = "Sidekick Occluded Window Capture Integration"
        let (window, occluder) = makeOccludedWindows(on: screen, title: title)
        defer {
            occluder.close()
            window.close()
        }
        let selection = WindowScreenshotSelection.Session()
        defer { selection.close() }

        let inventory = try await WindowScreenshotCapture.windows()
        let selectedWindow = try XCTUnwrap(inventory.windows.first(where: { $0.title == title }))
        selection.close()
        let image = try await WindowScreenshotCapture.capture(
            windowID: selectedWindow.id,
            from: inventory,
            showsCursor: false
        )

        XCTAssertEqual(image.width, Int((window.frame.width * screen.backingScaleFactor).rounded()))
        XCTAssertEqual(image.height, Int((window.frame.height * screen.backingScaleFactor).rounded()))
        let bitmap = NSBitmapImageRep(cgImage: image)
        let hiddenWindowPixel = try XCTUnwrap(
            bitmap.colorAt(x: image.width * 3 / 4, y: image.height / 2)?.usingColorSpace(.deviceRGB)
        )
        XCTAssertGreaterThan(hiddenWindowPixel.greenComponent, 0.8)
        XCTAssertLessThan(hiddenWindowPixel.redComponent, 0.2)
    }

    private func makeOccludedWindows(on screen: NSScreen, title: String) -> (NSWindow, NSWindow) {
        let window = NSWindow(
            contentRect: CGRect(x: screen.frame.minX + 40, y: screen.frame.minY + 40, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = title
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.green.cgColor
        window.contentView = contentView

        let frame = window.frame
        let occluder = NSWindow(
            contentRect: CGRect(
                x: frame.midX,
                y: frame.minY,
                width: frame.width / 2,
                height: frame.height
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        occluder.isReleasedWhenClosed = false
        occluder.isOpaque = true
        occluder.backgroundColor = .red

        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        occluder.orderFrontRegardless()
        window.displayIfNeeded()
        occluder.displayIfNeeded()
        return (window, occluder)
    }
}
