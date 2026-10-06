import Foundation

struct ClipboardChangeObservationState: Equatable {
    private(set) var observedChangeCount: Int?
    private(set) var generation: UInt64 = 0
    private var pendingChangeCount: Int?
    private var pendingGeneration: UInt64?

    mutating func seed(changeCount: Int) {
        observedChangeCount = changeCount
        pendingChangeCount = nil
        pendingGeneration = nil
    }

    mutating func rearm(changeCount: Int) {
        observedChangeCount = changeCount
        generation &+= 1
        pendingGeneration = generation
        pendingChangeCount = changeCount
    }

    mutating func observe(changeCount: Int) -> UInt64? {
        guard let observedChangeCount else {
            seed(changeCount: changeCount)
            return nil
        }
        if observedChangeCount != changeCount {
            self.observedChangeCount = changeCount
            generation &+= 1
            pendingGeneration = generation
            pendingChangeCount = changeCount
            return nil
        }
        guard pendingChangeCount == changeCount else { return nil }
        defer {
            pendingChangeCount = nil
            pendingGeneration = nil
        }
        return pendingGeneration
    }

    mutating func invalidate() {
        observedChangeCount = nil
        pendingChangeCount = nil
        pendingGeneration = nil
        generation &+= 1
    }

    func isCurrentGeneration(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}
