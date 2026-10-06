@testable import TiktokenSwiftPort
import XCTest

final class O200kBaseTests: XCTestCase {
    func testReferenceVectors() throws {
        let encoder = try O200kBase()
        let vectors: [(String, [UInt32])] = [
            ("", []),
            ("hello", [24_912]),
            ("hello world", [24_912, 2_375]),
            (
                "The quick brown fox jumps over the lazy dog.",
                [976, 4_853, 19_705, 68_347, 65_613, 1_072, 290, 29_082, 6_446, 13]
            ),
            ("today\n ", [58_744, 198, 220]),
            ("today\n \n", [58_744, 47_812]),
            ("today\n  \n", [58_744, 31_835]),
            ("1234567890", [7_633, 19_354, 29_338, 15]),
            ("rer", [27_653]),
            ("'rer", [15_770, 259]),
            ("can't won't we're I'll", [111_833, 14_219, 15_929, 17_291]),
            ("你好 世界", [177_519, 185_558]),
            (
                "我非常渴望与人工智能一起工作",
                [7_522, 71_165, 3_394, 112, 30_611, 11_755, 47_243, 60_319, 94_420, 22_369]
            ),
            ("😀👍🏽 café naïve", [84_083, 82_514, 52_622, 121, 30_469, 153_475, 737]),
            ("<|endoftext|>", [27, 91, 419, 1_440, 919, 91, 29]),
            ("a/b/c\\d", [64, 7_611, 4_308, 82_481])
        ]

        for (text, expected) in vectors {
            XCTAssertEqual(encoder.encode(text), expected, text)
        }
    }
    func testRepeatedBundledInitializationPreservesEncoding() throws {
        let text = "The quick brown fox 😀 12345"
        let expected = try O200kBase().encodeOrdinary(text)

        for _ in 0..<8 {
            XCTAssertEqual(try O200kBase().encodeOrdinary(text), expected)
        }
    }

    func testTokensPreserveMultibyteSourceRanges() throws {
        let encoder = try O200kBase()
        let text = "😀👍🏽 café\n你好 世界"
        let source = Array(text.utf8)
        let tokens = encoder.tokens(in: text)

        XCTAssertEqual(tokens.map(\.id), encoder.encodeOrdinary(text))

        var offset = 0
        for token in tokens {
            XCTAssertEqual(token.byteRange.lowerBound, offset)
            XCTAssertEqual(token.byteRange.upperBound, offset + token.bytes.count)
            XCTAssertEqual(Array(token.bytes), Array(source[token.byteRange]))
            offset = token.byteRange.upperBound
        }
        XCTAssertEqual(offset, source.count)
    }

    func testDirectIDAndCountPathsMatchTokenMetadata() throws {
        let encoder = try O200kBase()
        let texts = [
            "",
            "hello world",
            "1234567890",
            "can't won't we're I'll",
            "😀👍🏽 café naïve",
            "today\n  \n",
            String(repeating: "x", count: 4_096)
        ]

        for text in texts {
            let ids = encoder.encodeOrdinary(text)
            let tokenIDs = encoder.tokens(in: text).map(\.id)
            XCTAssertEqual(ids, tokenIDs, text)
            XCTAssertEqual(encoder.countTokens(in: text), ids.count, text)
        }
    }

    func testCustomRanksPreserveNoMergeAndMergeTieBehavior() throws {
        var ranks: [Data: UInt32] = [:]
        for value in 0...255 {
            ranks[Data([UInt8(value)])] = UInt32(value)
        }
        ranks[Data([97, 98])] = 1_000
        ranks[Data([98, 99])] = 1_001
        ranks[Data([97, 98, 99])] = 1_002

        let encoder = try O200kBase(mergeableRanks: ranks)
        XCTAssertEqual(encoder.encodeOrdinary("xy"), [120, 121])
        XCTAssertEqual(encoder.encodeOrdinary("abcd"), [1_002, 100])
        XCTAssertEqual(encoder.countTokens(in: "abcd"), 2)

        let tokens = encoder.tokens(in: "abcd")
        XCTAssertEqual(tokens.map(\.id), [1_002, 100])
        XCTAssertEqual(tokens.map(\.byteRange), [0..<3, 3..<4])
    }

    func testTokensExposeSourceBytesWithoutDecoder() throws {
        let encoder = try O200kBase()
        let text = "hello world"
        let tokens = encoder.tokens(in: text)

        XCTAssertEqual(tokens.map(\.id), [24_912, 2_375])
        XCTAssertEqual(tokens.map(\.byteRange), [0..<5, 5..<11])
        XCTAssertEqual(tokens.map(\.text), ["hello", " world"])
        XCTAssertEqual(
            tokens.reduce(into: [UInt8]()) { $0.append(contentsOf: $1.bytes) },
            Array(text.utf8)
        )
    }

    func testCountMatchesEncoding() throws {
        let encoder = try O200kBase()
        let text = String(repeating: "x", count: 1_000_000)

        XCTAssertEqual(encoder.countTokens(in: text), 125_000)
        XCTAssertEqual(encoder.countTokens(in: text), encoder.encode(text).count)
    }

    func testStandardDataRequiresEveryByteToken() {
        XCTAssertThrowsError(try O200kBase(mergeableRanks: [:])) { error in
            XCTAssertEqual(error as? O200kBaseError, .missingByteToken(0))
        }
    }

    func testDataParserRejectsDuplicateRanks() {
        let data = Data("YQ== 0\nYg== 0\n".utf8)

        XCTAssertThrowsError(try O200kBase(data: data)) { error in
            XCTAssertEqual(error as? O200kBaseError, .duplicateRank(2))
        }
    }
}
