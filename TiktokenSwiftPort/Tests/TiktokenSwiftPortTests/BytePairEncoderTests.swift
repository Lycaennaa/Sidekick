@testable import TiktokenSwiftPort
import XCTest

final class BytePairEncoderTests: XCTestCase {
    func testMaterializedAndIDPathsMatchForMergedAndUnmergedSegments() throws {
        var ranks = Self.byteRanks()
        ranks[[97, 98]] = 1_000
        ranks[[98, 99]] = 1_001
        ranks[[97, 98, 99]] = 1_002

        let encoder = try BytePairEncoder(ranks: ranks)
        let piece: [UInt8] = [97, 98, 99, 100]
        let expected = [
            EncodedToken(id: 1_002, start: 10, end: 13),
            EncodedToken(id: 100, start: 13, end: 14)
        ]

        XCTAssertEqual(encoder.encode(piece: piece, sourceOffset: 10), expected)

        var ids: [UInt32] = [777]
        encoder.appendIDs(piece: piece, to: &ids)
        XCTAssertEqual(ids, [777, 1_002, 100])
        XCTAssertEqual(Array(ids.dropFirst()), expected.map(\.id))
    }

    func testEmptyExactAndSingleBytePathsPreserveOutputContracts() throws {
        var ranks = Self.byteRanks()
        ranks[[97, 98]] = 1_000
        let encoder = try BytePairEncoder(ranks: ranks)

        XCTAssertEqual(encoder.encode(piece: [], sourceOffset: 10), [])
        var ids: [UInt32] = [777]
        encoder.appendIDs(piece: [], to: &ids)
        XCTAssertEqual(ids, [777])

        XCTAssertEqual(
            encoder.encode(piece: [97, 98], sourceOffset: 10),
            [EncodedToken(id: 1_000, start: 10, end: 12)]
        )
        ids = [777]
        encoder.appendIDs(piece: [97, 98], to: &ids)
        XCTAssertEqual(ids, [777, 1_000])

        XCTAssertEqual(
            encoder.encode(piece: [120], sourceOffset: 10),
            [EncodedToken(id: 120, start: 10, end: 11)]
        )
        ids = [777]
        encoder.appendIDs(piece: [120], to: &ids)
        XCTAssertEqual(ids, [777, 120])
    }

    private static func byteRanks() -> [[UInt8]: UInt32] {
        var ranks: [[UInt8]: UInt32] = [:]
        for value in 0...255 {
            ranks[[UInt8(value)]] = UInt32(value)
        }
        return ranks
    }
}
