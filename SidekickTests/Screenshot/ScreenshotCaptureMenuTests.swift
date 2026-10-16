import AppKit
import XCTest

@MainActor
final class ScreenshotCaptureMenuTests: XCTestCase {
    private var captureCount = 0
    private var captureExpectation: XCTestExpectation?

    func testStatusMenuOffersOneCaptureScreenAction() async throws {
        captureCount = 0
        let screenshotMenu = ScreenshotCaptureMenu { [weak self] in
            self?.captureCount += 1
            self?.captureExpectation?.fulfill()
        }
        let menu = NSMenu()
        screenshotMenu.add(to: menu)

        XCTAssertEqual(menu.items.count, 2)
        let captureItem = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(captureItem.title, "Capture Screen")
        XCTAssertNil(captureItem.submenu)
        XCTAssertTrue(captureItem.target === screenshotMenu)
        XCTAssertEqual(captureItem.action, #selector(ScreenshotCaptureMenu.captureScreen) as Selector?)
        XCTAssertTrue(menu.items[1].isSeparatorItem)

        let callback = expectation(description: "Capture screen callback")
        captureExpectation = callback
        screenshotMenu.captureScreen()
        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(captureCount, 1)
    }
}
