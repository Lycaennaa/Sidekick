import Foundation
@testable import TiktokenSwiftPort
import XCTest

final class O200kBaseParityTests: XCTestCase {
    private struct Vector: Decodable {
        let text: String
        let tokens: [UInt32]
    }

    func testMatchesOfficialTiktokenEncodeOrdinaryCorpus() throws {
        let resourceURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "o200k_base_encode_ordinary",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let vectors = try JSONDecoder().decode(
            [Vector].self,
            from: Data(contentsOf: resourceURL)
        )
        let encoder = try O200kBase()

        for (index, vector) in vectors.enumerated() {
            XCTAssertEqual(
                encoder.encodeOrdinary(vector.text),
                vector.tokens,
                "Corpus vector \(index): \(String(reflecting: vector.text))"
            )
        }
    }
}
