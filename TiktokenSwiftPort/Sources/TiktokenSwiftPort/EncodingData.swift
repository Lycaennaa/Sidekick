import Foundation

enum O200kBaseEncodingData {
    static func parse(_ data: Data) throws -> [[UInt8]: UInt32] {
        guard let content = String(data: data, encoding: .utf8) else {
            throw O200kBaseError.invalidUTF8
        }

        var ranks: [[UInt8]: UInt32] = [:]
        ranks.reserveCapacity(data.count / 8)
        var seenRanks = Set<UInt32>()

        for (lineNumber, line) in content.split(whereSeparator: \Character.isNewline).enumerated() {
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count == 2 else {
                throw O200kBaseError.malformedLine(lineNumber + 1)
            }
            guard let tokenData = Data(base64Encoded: String(fields[0])), !tokenData.isEmpty else {
                throw O200kBaseError.invalidToken(lineNumber + 1)
            }
            guard let rank = UInt32(fields[1]), rank != UInt32.max else {
                throw O200kBaseError.invalidRank(lineNumber + 1)
            }

            let token = Array(tokenData)
            guard ranks.updateValue(rank, forKey: token) == nil else {
                throw O200kBaseError.duplicateToken(lineNumber + 1)
            }
            guard seenRanks.insert(rank).inserted else {
                throw O200kBaseError.duplicateRank(lineNumber + 1)
            }
        }

        guard !ranks.isEmpty else { throw O200kBaseError.emptyEncoding }
        return ranks
    }
}
