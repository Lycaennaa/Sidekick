import Foundation

nonisolated final class ClipboardBackgroundWorkCoordinator<Work: Sendable, Output: Sendable>: @unchecked Sendable {
    typealias CancellationCheck = @Sendable () -> Bool
    typealias Operation = @Sendable (Work, CancellationCheck) -> Output?
    typealias ResultHandler = @MainActor @Sendable (Work, Output) -> Void
    typealias CancellationHandler = @MainActor @Sendable (Work) -> Void
    typealias PendingCancellationHandler = @MainActor @Sendable (Work) -> Void
    typealias DiscardHandler = @MainActor @Sendable (Work, Output) -> Void

    private struct Entry: Sendable {
        let id: UInt64
        let work: Work
        let operation: Operation
        let onResult: ResultHandler
        let onCancelled: CancellationHandler?
        let onPendingCancelled: PendingCancellationHandler?
        let onDiscarded: DiscardHandler?
    }

    // A cancelled native call can finish only after its synchronous operation returns.
    private let maximumConcurrentOperations = 2
    private let queue: DispatchQueue
    private let beforePerform: @Sendable () -> Void
    private let lock = NSLock()
    private var active: Entry?
    private var pending: Entry?
    private var runningIDs: Set<UInt64> = []
    private var nextWorkID: UInt64 = 0
    private var cancellationGeneration: UInt64 = 0
    private var activeCompletionDelivered = false

    init(
        label: String,
        beforePerform: @escaping @Sendable () -> Void = {}
    ) {
        self.beforePerform = beforePerform
        queue = DispatchQueue(
            label: label,
            qos: .userInitiated,
            attributes: .concurrent
        )
    }

    func enqueue(
        _ work: Work,
        operation: @escaping Operation,
        onResult: @escaping ResultHandler,
        onCancelled: CancellationHandler? = nil,
        onPendingCancelled: PendingCancellationHandler? = nil,
        onDiscarded: DiscardHandler? = nil
    ) {
        lock.lock()
        nextWorkID &+= 1
        let entry = Entry(
            id: nextWorkID,
            work: work,
            operation: operation,
            onResult: onResult,
            onCancelled: onCancelled,
            onPendingCancelled: onPendingCancelled,
            onDiscarded: onDiscarded
        )

        var entryToPerform: (Entry, UInt64)?
        var replacedPending: Entry?
        if active == nil || activeCompletionDelivered {
            if runningIDs.count < maximumConcurrentOperations {
                active = entry
                pending = nil
                activeCompletionDelivered = false
                runningIDs.insert(entry.id)
                entryToPerform = (entry, cancellationGeneration)
            } else {
                replacedPending = pending
                pending = entry
            }
        } else {
            replacedPending = pending
            pending = entry
        }
        lock.unlock()

        if let replacedPending {
            cancel(replacedPending, isPending: true)
        }
        if let entryToPerform {
            beforePerform()
            perform(entryToPerform.0, cancellationGeneration: entryToPerform.1)
        }
    }

    func cancelAll() {
        lock.lock()
        cancellationGeneration &+= 1
        let cancelledActive: Entry?
        if let active, !activeCompletionDelivered {
            activeCompletionDelivered = true
            cancelledActive = active
        } else {
            cancelledActive = nil
        }
        let cancelledPending = pending
        pending = nil
        lock.unlock()

        if let cancelledActive {
            cancel(cancelledActive, isPending: false)
        }
        if let cancelledPending {
            cancel(cancelledPending, isPending: true)
        }
    }

    private func cancel(_ entry: Entry, isPending: Bool) {
        let cancellationHandler = entry.onCancelled
        let pendingCancellationHandler = isPending ? entry.onPendingCancelled : nil
        guard cancellationHandler != nil || pendingCancellationHandler != nil else { return }
        DispatchQueue.main.async {
            cancellationHandler?(entry.work)
            pendingCancellationHandler?(entry.work)
        }
    }
    private func perform(_ entry: Entry, cancellationGeneration: UInt64) {
        queue.async { [self] in
            let output = entry.operation(entry.work) { [weak self] in
                self?.isCancelled(cancellationGeneration) ?? true
            }
            guard let output else {
                finishCurrentWork(for: entry.id)
                return
            }

            DispatchQueue.main.async { [self] in
                if claimCompletion(for: entry.id) {
                    entry.onResult(entry.work, output)
                } else {
                    entry.onDiscarded?(entry.work, output)
                }
                finishCurrentWork(for: entry.id)
            }
        }
    }

    private func isCancelled(_ cancellationGeneration: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationGeneration != self.cancellationGeneration
    }

    private func claimCompletion(for id: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active?.id == id, !activeCompletionDelivered else { return false }
        activeCompletionDelivered = true
        return true
    }

    private func finishCurrentWork(for id: UInt64) {
        lock.lock()
        guard runningIDs.remove(id) != nil else {
            lock.unlock()
            return
        }

        if active?.id == id {
            active = nil
            activeCompletionDelivered = false
        }

        var entryToPerform: (Entry, UInt64)?
        if let pending,
           active == nil || activeCompletionDelivered,
           runningIDs.count < maximumConcurrentOperations {
            active = pending
            self.pending = nil
            activeCompletionDelivered = false
            runningIDs.insert(pending.id)
            entryToPerform = (pending, cancellationGeneration)
        }
        lock.unlock()

        if let entryToPerform {
            beforePerform()
            perform(entryToPerform.0, cancellationGeneration: entryToPerform.1)
        }
    }
}
