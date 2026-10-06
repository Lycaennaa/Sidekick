import Foundation

actor PendingQueryGate {
    private var continuation: CheckedContinuation<Set<String>, Never>?

    var hasWaiter: Bool {
        continuation != nil
    }

    func wait() async -> Set<String> {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(with identifiers: Set<String>) {
        continuation?.resume(returning: identifiers)
        continuation = nil
    }
}

final class TokenStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    init(value: String?) {
        storedValue = value
    }

    var value: String? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiterReady: CheckedContinuation<Void, Never>?
    private var isOpen = false

    var hasWaiter: Bool {
        continuation != nil
    }

    func waitUntilWaiterAttached() async {
        guard continuation == nil, !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiterReady = continuation
        }
    }

    func wait() async {
        if isOpen {
            isOpen = false
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiterReady?.resume()
            waiterReady = nil
        }
    }

    func open() {
        if let continuation {
            continuation.resume()
            self.continuation = nil
        } else {
            isOpen = true
            waiterReady?.resume()
            waiterReady = nil
        }
    }
}

actor CancellationRecordingSleeper {
    private(set) var wasCancelled = false

    func sleep(_ interval: TimeInterval) async throws {
        do {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        } catch {
            wasCancelled = true
            throw error
        }
    }
}
