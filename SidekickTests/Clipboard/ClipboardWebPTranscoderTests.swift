import AppKit
import XCTest

@MainActor
final class ClipboardWebPTranscoderTests: XCTestCase {
    func testFileConversionStopsBeforeAggregateSourceBudget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let invalidURL = directory.appendingPathComponent("invalid.bin")
        let validURL = directory.appendingPathComponent("valid.png")
        try Data([0x00]).write(to: invalidURL)
        try pngData(width: 2, height: 2).write(to: validURL)

        XCTAssertThrowsError(
            try ClipboardWebPTranscoder.convert(
                .files([invalidURL, validURL], fallback: nil),
                outputDirectory: directory.appendingPathComponent("output"),
                aggregateSourceBytes: 1
            )
        ) { error in
            guard case ClipboardWebPTranscoder.ConversionError.invalidImage = error else {
                return XCTFail("Expected aggregate budget to stop before the valid file")
            }
        }
    }
    func testFallbackConsumesRemainingAggregateSourceBudget() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let invalidURL = directory.appendingPathComponent("invalid.bin")
        try Data([0x00]).write(to: invalidURL)
        let fallback = try pngData(width: 2, height: 2)

        XCTAssertThrowsError(
            try ClipboardWebPTranscoder.convert(
                .files([invalidURL], fallback: fallback),
                outputDirectory: directory.appendingPathComponent("output"),
                aggregateSourceBytes: 1
            )
        ) { error in
            guard case ClipboardWebPTranscoder.ConversionError.tooLarge = error else {
                return XCTFail("Expected fallback to consume the remaining aggregate budget")
            }
        }
    }
}
