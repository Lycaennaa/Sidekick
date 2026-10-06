import CoreAudio
import XCTest
final class TemporaryVolumeEventTests: XCTestCase {
    func testScheduledEventProvidesToastContent() {
        let content = TemporaryVolumeEvent.scheduled(
            deviceID: 42,
            startDelay: 15 * 60,
            duration: 3 * 60 * 60
        ).toastContent

        XCTAssertEqual(content.message, "Mute scheduled in 15 minutes for 3 hours")
        XCTAssertEqual(content.symbolName, "timer")
    }
}
