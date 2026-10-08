import Foundation

// One instance is retained by the coordinator patch task until completion; NSLock guards all cross-executor mutable state.
nonisolated final class DiscordPatchOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false
    private var commitAdmitted = false

    func requestCancellation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !commitAdmitted else { return false }
        cancellationRequested = true
        return true
    }

    func admitCommit() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !cancellationRequested else { throw CancellationError() }
        commitAdmitted = true
    }
}
