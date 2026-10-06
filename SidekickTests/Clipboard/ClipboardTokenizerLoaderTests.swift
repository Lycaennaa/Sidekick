import XCTest

@MainActor
final class ClipboardTokenizerLoaderTests: XCTestCase {
    func testTokenizerLoaderUsesBundledO200kBaseEncoding() async throws {
        let encoder = try await ClipboardTokenizerLoader().load()

        XCTAssertEqual(encoder.encodeOrdinary("hello world"), [24_912, 2_375])
        XCTAssertEqual(
            encoder.encodeOrdinary("The quick brown fox jumps over the lazy dog."),
            [976, 4_853, 19_705, 68_347, 65_613, 1_072, 290, 29_082, 6_446, 13]
        )
    }
}
