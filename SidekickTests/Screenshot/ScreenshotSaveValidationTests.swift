import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ScreenshotSaveValidationTests: XCTestCase {
    func testFilenameTemplateExpandsDateTimeAndOptionalWindowTitle() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = Date(timeIntervalSince1970: 0)

        let titled = ScreenshotFilenameTemplate.baseName(
            template: "Shot_{date}_{time}_{windowTitle}",
            date: date,
            windowTitle: "Editor/Window: Main",
            timeZone: timeZone
        )
        let withoutTitle = ScreenshotFilenameTemplate.baseName(
            template: "Shot_{date}_{windowTitle}",
            date: date,
            windowTitle: nil,
            timeZone: timeZone
        )

        XCTAssertEqual(titled, "Shot_1970-01-01_00-00-00_Editor-Window- Main")
        XCTAssertEqual(withoutTitle, "Shot_1970-01-01")
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
