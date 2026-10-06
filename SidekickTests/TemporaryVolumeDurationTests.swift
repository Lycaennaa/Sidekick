import Foundation
import XCTest
final class TemporaryVolumeDurationTests: XCTestCase {
    func testParsesPlainAndCompoundDurations() {
        XCTAssertEqual(TemporaryVolumeDuration.interval(from: " 1.5 "), 90)
        XCTAssertEqual(TemporaryVolumeDuration.interval(from: "1h 30m"), 90 * 60)
        XCTAssertEqual(TemporaryVolumeDuration.interval(from: "90m"), 90 * 60)
        XCTAssertEqual(TemporaryVolumeDuration.interval(from: "1d 2h 30m"), 26.5 * 60 * 60)
        XCTAssertEqual(TemporaryVolumeDuration.interval(from: "10080"), 7 * 24 * 60 * 60)
    }

    func testRejectsInvalidOrUnboundedDurations() {
        XCTAssertNil(TemporaryVolumeDuration.interval(from: "0"))
        XCTAssertNil(TemporaryVolumeDuration.interval(from: "-1"))
        XCTAssertNil(TemporaryVolumeDuration.interval(from: "1h 30"))
        XCTAssertNil(TemporaryVolumeDuration.interval(from: "not a duration"))
        XCTAssertNil(TemporaryVolumeDuration.interval(from: "10080.01"))
    }
}
