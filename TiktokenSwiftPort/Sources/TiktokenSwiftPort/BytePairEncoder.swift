import Foundation

struct EncodedToken: Equatable, Sendable {
    let id: UInt32
    let start: Int
    let end: Int
}

enum BytePairEncoderError: Error, Equatable, Sendable {
    case invalidRank(UInt32)
    case duplicateRank(UInt32)
    case missingByteToken(UInt8)
}

struct BytePairEncoder: Sendable {
    private static let sentinel = UInt32.max

    private struct MergeState: Sendable {
        var previous: Int
        var end: Int
        var nextEnd: Int
        var nextRank: UInt32
        var currentRank: UInt32
    }

    private struct MergeCandidate: Sendable {
        let start: Int
        let rank: UInt32
    }

    private struct MinHeap: Sendable {
        private var elements: [MergeCandidate] = []

        mutating func insert(_ candidate: MergeCandidate) {
            elements.append(candidate)
            var index = elements.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard comesBefore(elements[index], elements[parent]) else { break }
                elements.swapAt(index, parent)
                index = parent
            }
        }

        mutating func removeMin() -> MergeCandidate? {
            guard !elements.isEmpty else { return nil }
            if elements.count == 1 { return elements.removeLast() }

            let result = elements[0]
            let last = elements.removeLast()
            elements[0] = last
            var index = 0
            while true {
                let left = index * 2 + 1
                guard left < elements.count else { break }
                var child = left
                let right = left + 1
                if right < elements.count,
                   comesBefore(elements[right], elements[left]) {
                    child = right
                }
                guard comesBefore(elements[child], elements[index]) else { break }
                elements.swapAt(index, child)
                index = child
            }
            return result
        }

        private func comesBefore(
            _ lhs: MergeCandidate,
            _ rhs: MergeCandidate
        ) -> Bool {
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.start < rhs.start
        }
    }

    private let ranks: [ArraySlice<UInt8>: UInt32]
    private let pairRanks: [UInt32]

    init(ranks: [[UInt8]: UInt32]) throws {
        var seenRanks = Set<UInt32>(minimumCapacity: ranks.count)
        for rank in ranks.values {
            guard rank != Self.sentinel else {
                throw BytePairEncoderError.invalidRank(rank)
            }
            guard seenRanks.insert(rank).inserted else {
                throw BytePairEncoderError.duplicateRank(rank)
            }
        }

        for value in 0...255 {
            let byte = UInt8(value)
            guard ranks[[byte]] != nil else {
                throw BytePairEncoderError.missingByteToken(byte)
            }
        }

        var sequenceRanks: [ArraySlice<UInt8>: UInt32] = [:]
        sequenceRanks.reserveCapacity(ranks.count)
        for (token, rank) in ranks {
            sequenceRanks[token[...]] = rank
        }

        var pairRanks = Array(repeating: Self.sentinel, count: 256 * 256)
        for (token, rank) in ranks where token.count == 2 {
            let index = (Int(token[0]) << 8) | Int(token[1])
            pairRanks[index] = rank
        }

        self.ranks = sequenceRanks
        self.pairRanks = pairRanks
    }

    func encode(piece: [UInt8], sourceOffset: Int) -> [EncodedToken] {
        guard !piece.isEmpty else { return [] }
        if let rank = ranks[piece[...]] {
            return [EncodedToken(
                id: rank,
                start: sourceOffset,
                end: sourceOffset + piece.count
            )]
        }
        return bytePairEncode(piece: piece, sourceOffset: sourceOffset)
    }

    func appendIDs(piece: [UInt8], to ids: inout [UInt32]) {
        guard !piece.isEmpty else { return }
        if let rank = ranks[piece[...]] {
            ids.append(rank)
            return
        }
        appendBytePairIDs(piece: piece, to: &ids)
    }

    func count(piece: [UInt8]) -> Int {
        guard !piece.isEmpty else { return 0 }
        guard ranks[piece[...]] == nil else { return 1 }
        return mergedStates(for: piece).tokenCount
    }

    private func bytePairEncode(piece: [UInt8], sourceOffset: Int) -> [EncodedToken] {
        let merged = mergedStates(for: piece)
        var result: [EncodedToken] = []
        result.reserveCapacity(merged.tokenCount)
        emitMergedTokens(piece: piece, states: merged.states) { start, end, rank in
            result.append(EncodedToken(
                id: rank,
                start: sourceOffset + start,
                end: sourceOffset + end
            ))
        }
        return result
    }

    private func appendBytePairIDs(piece: [UInt8], to ids: inout [UInt32]) {
        let merged = mergedStates(for: piece)
        ids.reserveCapacity(ids.count + merged.tokenCount)
        emitMergedTokens(piece: piece, states: merged.states) { _, _, rank in
            ids.append(rank)
        }
    }

    private func emitMergedTokens(
        piece: [UInt8],
        states: [MergeState],
        _ body: (Int, Int, UInt32) -> Void
    ) {
        var start = 0
        while start < states.count {
            let end = states[start].end
            let rank: UInt32
            if states[start].currentRank != Self.sentinel {
                rank = states[start].currentRank
            } else {
                rank = requiredRank(of: piece, start: start, end: end)
            }
            body(start, end, rank)
            start = end
        }
    }

    private func mergedStates(for piece: [UInt8]) -> (states: [MergeState], tokenCount: Int) {
        precondition(piece.count > 1)

        var states: [MergeState] = []
        states.reserveCapacity(piece.count)
        states.append(MergeState(
            previous: -1,
            end: 1,
            nextEnd: 2,
            nextRank: Self.sentinel,
            currentRank: Self.sentinel
        ))

        var heap = MinHeap()
        for index in 0..<(piece.count - 1) {
            let rank = rank(of: piece, start: index, end: index + 2)
            if rank != Self.sentinel {
                heap.insert(MergeCandidate(start: index, rank: rank))
                states[index].nextRank = rank
            }
            states.append(MergeState(
                previous: index,
                end: index + 2,
                nextEnd: index + 3,
                nextRank: Self.sentinel,
                currentRank: Self.sentinel
            ))
        }

        var tokenCount = piece.count
        while let candidate = heap.removeMin() {
            guard candidate.rank == states[candidate.start].nextRank else { continue }
            tokenCount -= 1

            let leftStart = candidate.start
            let rightStart = states[leftStart].end
            let rightEnd = states[leftStart].nextEnd
            let rightNextEnd = states[rightStart].nextEnd

            states[leftStart].currentRank = states[leftStart].nextRank
            states[leftStart].end = rightEnd
            addPotentialMerge(
                start: leftStart,
                nextEnd: rightNextEnd,
                piece: piece,
                states: &states,
                heap: &heap
            )

            if rightEnd < states.count {
                states[rightEnd].previous = leftStart
            }
            if leftStart > 0 {
                addPotentialMerge(
                    start: states[leftStart].previous,
                    nextEnd: rightEnd,
                    piece: piece,
                    states: &states,
                    heap: &heap
                )
            }
            states[rightStart].nextRank = Self.sentinel
        }

        return (states, tokenCount)
    }

    private func addPotentialMerge(
        start: Int,
        nextEnd: Int,
        piece: [UInt8],
        states: inout [MergeState],
        heap: inout MinHeap
    ) {
        states[start].nextEnd = nextEnd
        states[start].nextRank = Self.sentinel
        guard nextEnd <= piece.count else { return }

        let rank = rank(of: piece, start: start, end: nextEnd)
        guard rank != Self.sentinel else { return }
        states[start].nextRank = rank
        heap.insert(MergeCandidate(start: start, rank: rank))
    }

    private func rank(of piece: [UInt8], start: Int, end: Int) -> UInt32 {
        if end - start == 2 {
            return pairRanks[(Int(piece[start]) << 8) | Int(piece[start + 1])]
        }
        return ranks[piece[start..<end]] ?? Self.sentinel
    }

    private func requiredRank(of piece: [UInt8], start: Int, end: Int) -> UInt32 {
        guard let rank = ranks[piece[start..<end]] else {
            preconditionFailure("O200k_base has no rank for a merged byte sequence")
        }
        return rank
    }
}
