import Foundation

public enum O200kBaseError: Error, Equatable, Sendable {
    case bundledEncodingUnavailable
    case bundledEncodingUnreadable
    case invalidUTF8
    case malformedLine(Int)
    case invalidToken(Int)
    case invalidRank(Int)
    case duplicateToken(Int)
    case duplicateRank(Int)
    case emptyEncoding
    case invalidRankValue(UInt32)
    case duplicateRankValue(UInt32)
    case missingByteToken(UInt8)
}

public struct O200kBase: Sendable {
    public struct Token: Equatable, Sendable {
        public let id: UInt32
        public let byteRange: Range<Int>
        public let bytes: Data

        public var text: String? {
            String(data: bytes, encoding: .utf8)
        }

        fileprivate init(id: UInt32, byteRange: Range<Int>, bytes: Data) {
            self.id = id
            self.byteRange = byteRange
            self.bytes = bytes
        }
    }

    public static let name = "o200k_base"
    public static let endOfTextToken: UInt32 = 199_999
    public static let endOfPromptToken: UInt32 = 200_018

    private static let matcher = UnicodePattern(
        #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*"#
            + #"[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?|"#
            + #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+"#
            + #"[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?|"#
            + #"\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n/]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
    )

    private let encoder: BytePairEncoder

    private static let bundledEncoder: Result<BytePairEncoder, O200kBaseError> = {
        guard let url = Bundle.module.url(
            forResource: "o200k_base",
            withExtension: "tiktoken"
        ) else {
            return .failure(.bundledEncodingUnavailable)
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.bundledEncodingUnreadable)
        }

        do {
            let ranks = try O200kBaseEncodingData.parse(data)
            return .success(try Self.makeEncoder(ranks: ranks))
        } catch let error as O200kBaseError {
            return .failure(error)
        } catch {
            preconditionFailure("Unexpected bundled encoding error: \(error)")
        }
    }()

    public init() throws {
        encoder = try Self.bundledEncoder.get()
    }

    public init(data: Data) throws {
        try self.init(ranks: O200kBaseEncodingData.parse(data))
    }

    public init(mergeableRanks: [Data: UInt32]) throws {
        var ranks: [[UInt8]: UInt32] = [:]
        ranks.reserveCapacity(mergeableRanks.count)
        for (token, rank) in mergeableRanks {
            ranks[Array(token)] = rank
        }
        try self.init(ranks: ranks)
    }

    public func encode(_ text: String) -> [UInt32] {
        encodeOrdinary(text)
    }

    public func encodeOrdinary(_ text: String) -> [UInt32] {
        var ids: [UInt32] = []
        ids.reserveCapacity(max(1, text.utf8.count / 4))
        forEachMatch(in: text) { piece, _ in
            encoder.appendIDs(piece: Array(piece.utf8), to: &ids)
        }
        return ids
    }

    public func countTokens(in text: String) -> Int {
        var count = 0
        forEachMatch(in: text) { piece, _ in
            count += encoder.count(piece: Array(piece.utf8))
        }
        return count
    }

    public func tokens(in text: String) -> [Token] {
        let encoded = encodedTokens(in: text)
        return encoded.tokens.map { token in
            let range = token.start..<token.end
            return Token(
                id: token.id,
                byteRange: range,
                bytes: encoded.source[range]
            )
        }
    }
    private static func makeEncoder(ranks: [[UInt8]: UInt32]) throws -> BytePairEncoder {
        do {
            return try BytePairEncoder(ranks: ranks)
        } catch let error as BytePairEncoderError {
            switch error {
            case let .invalidRank(rank):
                throw O200kBaseError.invalidRankValue(rank)
            case let .duplicateRank(rank):
                throw O200kBaseError.duplicateRankValue(rank)
            case let .missingByteToken(byte):
                throw O200kBaseError.missingByteToken(byte)
            }
        }
    }

    private init(ranks: [[UInt8]: UInt32]) throws {
        encoder = try Self.makeEncoder(ranks: ranks)
    }
    private func encodedTokens(in text: String) -> (source: Data, tokens: [EncodedToken]) {
        let source = Data(text.utf8)
        var tokens: [EncodedToken] = []
        tokens.reserveCapacity(max(1, source.count / 4))

        forEachMatch(in: text, sourceByteCount: source.count) { piece, sourceOffset in
            tokens.append(contentsOf: encoder.encode(
                piece: Array(piece.utf8),
                sourceOffset: sourceOffset
            ))
        }
        return (source, tokens)
    }

    private func forEachMatch(
        in text: String,
        sourceByteCount: Int? = nil,
        _ body: (Substring, Int) -> Void
    ) {
        var sourceByteOffset = 0
        var utf16Offset = 0
        let expectedSourceByteCount = sourceByteCount ?? text.utf8.count
        let fullRange = NSRange(location: 0, length: text.utf16.count)
        Self.matcher.regex.enumerateMatches(in: text, options: [], range: fullRange) { match, _, _ in
            guard let match, let matchRange = Range(match.range, in: text) else { return }
            precondition(
                match.range.location == utf16Offset,
                "O200k_base pattern left an unmatched text range"
            )
            let piece = text[matchRange]
            body(piece, sourceByteOffset)
            sourceByteOffset += piece.utf8.count
            utf16Offset = NSMaxRange(match.range)
        }

        precondition(
            utf16Offset == text.utf16.count && sourceByteOffset == expectedSourceByteCount,
            "O200k_base pattern did not cover the input"
        )
    }

}

private final class UnicodePattern: @unchecked Sendable {
    let regex: NSRegularExpression

    init(_ pattern: String) {
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid O200k_base regex: \(error)")
        }
    }
}
