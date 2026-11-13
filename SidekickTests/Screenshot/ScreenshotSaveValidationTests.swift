import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ScreenshotSaveValidationTests: XCTestCase {
    func testFilenameTemplateExpandsDateTimeAndWindowTitle() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = Date(timeIntervalSince1970: 0)

        let expanded = ScreenshotFilenameTemplate.baseName(
            template: "Shot_{date}_{time}",
            date: date,
            timeZone: timeZone
        )
        let windowTitle = ScreenshotFilenameTemplate.baseName(
            template: "Shot_{date}_{windowTitle}",
            date: date,
            timeZone: timeZone,
            windowTitle: "Window:Name"
        )

        XCTAssertEqual(expanded, "Shot_1970-01-01_00-00-00")
        XCTAssertEqual(windowTitle, "Shot_1970-01-01_Window-Name")
        XCTAssertFalse(ScreenshotFilenameTemplate.sanitizedBaseName("../../Screenshots/../Desktop").contains("/"))
    }

    func testFilenameTemplateExpandsIndividualDateTimeAndRandomTags() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let expanded = ScreenshotFilenameTemplate.baseName(
            template: "{year}-{month}-{day}_{hour}-{minute}-{second}_{windowTitle}_{random}",
            date: Date(timeIntervalSince1970: 0),
            timeZone: timeZone,
            windowTitle: "Window:Name",
            randomValue: "aB12cD3"
        )

        XCTAssertEqual(expanded, "1970-01-01_00-00-00_Window-Name_aB12cD3")
    }

    func testRandomTagGeneratesImageConversionFilenameString() {
        let randomValue = ScreenshotFilenameTemplate.baseName(
            template: "{random}",
            date: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(randomValue.count, 7)
        XCTAssertTrue(randomValue.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
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
