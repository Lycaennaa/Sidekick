import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ScreenshotSaveValidationTests: XCTestCase {
    func testFilenameTemplateExpandsDateTimeAndIgnoresLegacyWindowTitle() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = Date(timeIntervalSince1970: 0)

        let expanded = ScreenshotFilenameTemplate.baseName(
            template: "Shot_{date}_{time}",
            date: date,
            timeZone: timeZone
        )
        let legacyTemplate = ScreenshotFilenameTemplate.baseName(
            template: "Shot_{date}_{windowTitle}",
            date: date,
            timeZone: timeZone
        )

        XCTAssertEqual(expanded, "Shot_1970-01-01_00-00-00")
        XCTAssertEqual(legacyTemplate, "Shot_1970-01-01")
        XCTAssertFalse(ScreenshotFilenameTemplate.sanitizedBaseName("../../Screenshots/../Desktop").contains("/"))
    }

    func testInvalidSaveFolderIsRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-folder")
        try Data([1]).write(to: file)

        XCTAssertThrowsError(
            try ScreenshotSaveService.prepare(
                pngData: try pngData(width: 1, height: 1),
                directory: file,
                baseName: "Screenshot",
                isCancelled: { false }
            )
        ) { error in
            XCTAssertEqual(error as? ScreenshotSaveService.Failure, .invalidDirectory)
        }
    }
}
