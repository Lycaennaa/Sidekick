import CoreGraphics
import XCTest

final class ToastLayoutTests: XCTestCase {
    func testFrameUsesBottomCenterInsetAndBoundsSize() {
        let frame = ToastLayout.frame(
            contentSize: CGSize(width: 750, height: 300),
            in: CGRect(x: 100, y: 50, width: 1_000, height: 700)
        )

        XCTAssertEqual(frame, CGRect(x: 225, y: 66, width: 750, height: 300))
    }

    func testFrameStaysInsideSmallVisibleFrame() {
        let visibleFrame = CGRect(x: -200, y: 20, width: 200, height: 100)
        let frame = ToastLayout.frame(
            contentSize: CGSize(width: 420, height: 120),
            in: visibleFrame
        )

        XCTAssertEqual(frame, CGRect(x: -184, y: 36, width: 168, height: 68))
        XCTAssertTrue(visibleFrame.contains(frame))
    }
    func testTwitchMaximumSizeMatchesOverallMaximum() {
        XCTAssertEqual(
            ToastLayout.twitchMaximumSize,
            ToastLayout.maximumSize
        )

        let frame = ToastLayout.frame(
            contentSize: ToastLayout.maximumSize,
            in: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            maximumSize: ToastLayout.twitchMaximumSize
        )

        XCTAssertEqual(frame.size, ToastLayout.twitchMaximumSize)
    }

    func testStackedFrameStartsAbovePreviousToast() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        let firstFrame = ToastLayout.frame(
            contentSize: CGSize(width: 400, height: 180),
            in: visibleFrame
        )
        let secondFrame = ToastLayout.frame(
            contentSize: CGSize(width: 400, height: 180),
            in: visibleFrame,
            bottomOffset: firstFrame.height + ToastLayout.stackSpacing
        )

        XCTAssertFalse(firstFrame.intersects(secondFrame))
        XCTAssertEqual(secondFrame.minY, firstFrame.maxY + ToastLayout.stackSpacing)
    }
}
