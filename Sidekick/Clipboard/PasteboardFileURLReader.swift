import AppKit

/// Result of a bounded pasteboard data read.
///
/// `tooLarge` rejects materialized output after its size is known. `timedOut` and
/// `cancelled` return to the caller without preempting a provider call; running
/// calls remain quarantined until they return.
enum PasteboardBoundedReadResult: Equatable, Sendable {
    case missing
    case data(Data)
    case tooLarge(byteCount: Int)
    case timedOut
    case cancelled
    case unavailable
    case failed
}

typealias PasteboardFileURLReadResult = PasteboardBoundedReadResult
typealias PasteboardProviderOperationResult = PasteboardBoundedReadResult
typealias PasteboardProviderMaterialization = PasteboardBoundedReadResult

protocol PasteboardFileURLReading {
    /// `maximumBytes` limits bytes accepted from the materialized result;
    /// it is not an allocation cap.
    /// `timeout` is a result deadline. A native provider call can continue in
    /// a quarantined worker slot after it expires.
    @MainActor
    func readFileURLData(
        from item: NSPasteboardItem,
        maximumBytes: Int,
        timeout: TimeInterval
    ) async -> PasteboardFileURLReadResult
}

nonisolated final class PasteboardProviderOperationOwner: @unchecked Sendable {
    typealias Materialize = @Sendable (@Sendable () -> Bool) -> PasteboardProviderMaterialization

    private static let maximumConcurrentOperationLimit = 2
    private static let maximumQueuedOperationLimit = 4

    static let shared = PasteboardProviderOperationOwner(
        maximumConcurrentOperations: maximumConcurrentOperationLimit,
        maximumQueuedOperations: maximumQueuedOperationLimit
    )

    // Provider calls are non-preemptible. `maximumBytes` accepts at most that many
    // returned bytes; it cannot cap provider allocation before materialization returns.
    // A timeout or cancellation quarantines a running slot until the provider returns.
    private enum RequestState {
        case created
        case queued
        case running
        case quarantined
        case finished
    }

    nonisolated private final class Request: @unchecked Sendable {
        let maximumAcceptedBytes: Int
        let materialize: Materialize
        let deadline: DispatchTime
        var continuation: CheckedContinuation<PasteboardProviderOperationResult, Never>?
        var state = RequestState.created
        var timeoutWorkItem: DispatchWorkItem?

        init(
            maximumAcceptedBytes: Int,
            deadline: DispatchTime,
            materialize: @escaping Materialize,
            continuation: CheckedContinuation<PasteboardProviderOperationResult, Never>
        ) {
            self.maximumAcceptedBytes = maximumAcceptedBytes
            self.deadline = deadline
            self.materialize = materialize
            self.continuation = continuation
        }
    }

    nonisolated private final class CancellationRegistration: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () -> Void)?
        private var cancelled = false

        func install(_ action: @escaping @Sendable () -> Void) {
            lock.lock()
            guard !cancelled else {
                lock.unlock()
                action()
                return
            }
            self.action = action
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let action = self.action
            self.action = nil
            lock.unlock()
            action?()
        }
    }

    private let maximumConcurrentOperations: Int
    private let maximumQueuedOperations: Int
    private let workerQueue: DispatchQueue
    private let timeoutQueue: DispatchQueue
    private let lock = NSLock()
    private var activeOperationCount = 0
    private var pendingRequests: [Request] = []

    init(
        maximumConcurrentOperations: Int = 2,
        maximumQueuedOperations: Int = 4
    ) {
        self.maximumConcurrentOperations = min(
            max(1, maximumConcurrentOperations),
            Self.maximumConcurrentOperationLimit
        )
        self.maximumQueuedOperations = min(
            max(0, maximumQueuedOperations),
            Self.maximumQueuedOperationLimit
        )
        workerQueue = DispatchQueue(
            label: "com.lycaennaa.sidekick.pasteboard-provider",
            qos: .utility,
            attributes: .concurrent
        )
        timeoutQueue = DispatchQueue(
            label: "com.lycaennaa.sidekick.pasteboard-provider-timeouts",
            qos: .utility
        )
    }

    /// `maximumBytes` is an accepted-output limit checked after materialization.
    /// `timeout` bounds result delivery; it cannot interrupt a provider call.
    func readData(
        maximumBytes: Int,
        timeout: TimeInterval,
        materialize: @escaping Materialize
    ) async -> PasteboardProviderOperationResult {
        guard maximumBytes >= 0, timeout.isFinite, timeout >= 0 else {
            return .unavailable
        }
        guard !Task.isCancelled else { return .cancelled }
        let deadline = DispatchTime.now() + timeout

        let cancellation = CancellationRegistration()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let request = Request(
                    maximumAcceptedBytes: maximumBytes,
                    deadline: deadline,
                    materialize: materialize,
                    continuation: continuation
                )
                cancellation.install { [self, weak request] in
                    guard let request else { return }
                    abandon(request, result: .cancelled)
                }
                guard !Task.isCancelled else {
                    abandon(request, result: .cancelled)
                    return
                }
                enqueue(request)
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    private func enqueue(_ request: Request) {
        let timeoutWorkItem = DispatchWorkItem { [self, weak request] in
            guard let request else { return }
            abandon(request, result: .timedOut)
        }
        var shouldStart = false
        var rejectedContinuation: CheckedContinuation<PasteboardProviderOperationResult, Never>?

        lock.lock()
        guard request.state == .created else {
            lock.unlock()
            return
        }
        request.timeoutWorkItem = timeoutWorkItem
        if activeOperationCount < maximumConcurrentOperations {
            request.state = .running
            activeOperationCount += 1
            shouldStart = true
        } else if pendingRequests.count < maximumQueuedOperations {
            request.state = .queued
            pendingRequests.append(request)
        } else {
            request.state = .finished
            rejectedContinuation = request.continuation
            request.continuation = nil
        }
        lock.unlock()

        if let rejectedContinuation {
            rejectedContinuation.resume(returning: .unavailable)
            return
        }

        timeoutQueue.asyncAfter(
            deadline: request.deadline,
            execute: timeoutWorkItem
        )
        if shouldStart {
            start(request)
        }
    }

    private func start(_ request: Request) {
        workerQueue.async { [self, request] in
            let result: PasteboardProviderOperationResult = autoreleasepool {
                guard isMaterializationAllowed(request) else { return .missing }
                let materialization = request.materialize { [self, weak request] in
                    guard let request else { return false }
                    return self.isMaterializationAllowed(request)
                }
                guard isMaterializationAllowed(request) else { return .missing }
                guard case let .data(data) = materialization else {
                    return materialization
                }
                guard data.count <= request.maximumAcceptedBytes else {
                    return .tooLarge(byteCount: data.count)
                }
                return .data(data)
            }
            complete(request, result: result)
        }
    }

    private func isMaterializationAllowed(_ request: Request) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request.state == .running
            && DispatchTime.now().uptimeNanoseconds < request.deadline.uptimeNanoseconds
    }

    private func abandon(
        _ request: Request,
        result: PasteboardProviderOperationResult
    ) {
        var continuation: CheckedContinuation<PasteboardProviderOperationResult, Never>?
        var timeoutWorkItem: DispatchWorkItem?

        lock.lock()
        switch request.state {
        case .created:
            request.state = .finished
            continuation = request.continuation
            request.continuation = nil
        case .queued:
            pendingRequests.removeAll { $0 === request }
            request.state = .finished
            continuation = request.continuation
            request.continuation = nil
        case .running:
            request.state = .quarantined
            continuation = request.continuation
            request.continuation = nil
        case .quarantined, .finished:
            break
        }
        timeoutWorkItem = request.timeoutWorkItem
        request.timeoutWorkItem = nil
        lock.unlock()

        timeoutWorkItem?.cancel()
        continuation?.resume(returning: result)
    }

    private func complete(
        _ request: Request,
        result: PasteboardProviderOperationResult
    ) {
        var continuation: CheckedContinuation<PasteboardProviderOperationResult, Never>?
        var timeoutWorkItem: DispatchWorkItem?
        var requestsToStart: [Request] = []
        var resultToReturn: PasteboardProviderOperationResult?

        lock.lock()
        switch request.state {
        case .running:
            let timedOut = DispatchTime.now().uptimeNanoseconds >= request.deadline.uptimeNanoseconds
            request.state = .finished
            activeOperationCount -= 1
            continuation = request.continuation
            request.continuation = nil
            timeoutWorkItem = request.timeoutWorkItem
            request.timeoutWorkItem = nil
            resultToReturn = timedOut ? .timedOut : result
            requestsToStart = drainPendingRequests()
        case .quarantined:
            request.state = .finished
            activeOperationCount -= 1
            timeoutWorkItem = request.timeoutWorkItem
            request.timeoutWorkItem = nil
            requestsToStart = drainPendingRequests()
        case .created, .queued, .finished:
            break
        }
        lock.unlock()

        timeoutWorkItem?.cancel()
        continuation?.resume(returning: resultToReturn ?? result)
        requestsToStart.forEach(start)
    }

    private func drainPendingRequests() -> [Request] {
        var requestsToStart: [Request] = []
        while activeOperationCount < maximumConcurrentOperations,
              !pendingRequests.isEmpty {
            let request = pendingRequests.removeFirst()
            guard request.state == .queued else { continue }
            request.state = .running
            activeOperationCount += 1
            requestsToStart.append(request)
        }
        return requestsToStart
    }
}

private final class PasteboardNativeMaterializationRequest: @unchecked Sendable {
    nonisolated(unsafe) let item: NSPasteboardItem
    let type: NSPasteboard.PasteboardType

    init(item: NSPasteboardItem, type: NSPasteboard.PasteboardType) {
        self.item = item
        self.type = type
    }
}

enum PasteboardNativeMaterializationGateway {
    /// Reads a native item through the bounded provider owner.
    ///
    /// `maximumAcceptedBytes` is checked after `data(forType:)` returns, so it does
    /// not cap provider allocation. `deadlineInterval` bounds result delivery; it
    /// cannot interrupt provider work. A running request remains quarantined until
    /// its provider call returns.
    @MainActor
    static func readData(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType,
        maximumAcceptedBytes: Int,
        deadlineInterval: TimeInterval
    ) async -> PasteboardProviderOperationResult {
        let request = PasteboardNativeMaterializationRequest(item: item, type: type)
        return await PasteboardProviderOperationOwner.shared.readData(
            maximumBytes: maximumAcceptedBytes,
            timeout: deadlineInterval,
            materialize: { isActive in
                guard isActive(),
                      let data = request.item.data(forType: request.type) else {
                    return .missing
                }
                guard isActive() else { return .missing }
                guard data.count <= maximumAcceptedBytes else {
                    return .tooLarge(byteCount: data.count)
                }
                return .data(data)
            }
        )
    }
}

struct SystemPasteboardFileURLReader: PasteboardFileURLReading {
    static let maximumAcceptedBytes = 1 * 1_024 * 1_024
    static let resultDeadlineInterval: TimeInterval = 0.25

    @MainActor
    func readFileURLData(
        from item: NSPasteboardItem,
        maximumBytes: Int,
        timeout: TimeInterval
    ) async -> PasteboardFileURLReadResult {
        guard !Task.isCancelled else { return .cancelled }
        guard maximumBytes >= 0 else { return .unavailable }
        let result = await PasteboardNativeMaterializationGateway.readData(
            from: item,
            forType: .fileURL,
            maximumAcceptedBytes: maximumBytes,
            deadlineInterval: timeout
        )
        guard !Task.isCancelled else { return .cancelled }
        return result
    }

    /// Explicit test seam using the same provider-operation owner.
    /// `maximumBytes` is an accepted-output limit; `timeout` bounds result
    /// delivery only.
    static func readInjectedData(
        maximumBytes: Int,
        timeout: TimeInterval,
        materialize: @escaping @Sendable () -> Data?
    ) async -> PasteboardFileURLReadResult {
        guard !Task.isCancelled else { return .cancelled }
        guard maximumBytes >= 0, timeout.isFinite, timeout >= 0 else {
            return .unavailable
        }
        let result = await PasteboardProviderOperationOwner.shared.readData(
            maximumBytes: maximumBytes,
            timeout: timeout,
            materialize: { _ in
                guard let data = materialize() else { return .missing }
                return .data(data)
            }
        )
        guard !Task.isCancelled else { return .cancelled }
        return result
    }
}
