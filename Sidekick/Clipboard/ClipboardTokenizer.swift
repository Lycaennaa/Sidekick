import Foundation
import TiktokenSwiftPort

nonisolated protocol ClipboardTokenizerLoading: AnyObject, Sendable {
    func load() async throws -> O200kBase
}

nonisolated final class ClipboardTokenizerLoader: ClipboardTokenizerLoading, Sendable {
    func load() async throws -> O200kBase {
        try Task.checkCancellation()
        let loadTask: Task<O200kBase, Error> = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try O200kBase()
        }
        return try await withTaskCancellationHandler(operation: {
            try await loadTask.value
        }, onCancel: {
            loadTask.cancel()
        })
    }
}

actor ClipboardTokenizer {

    private let loader: any ClipboardTokenizerLoading
    private var encoder: O200kBase?
    private var encoderTask: Task<O200kBase, Error>?
    private var bootstrapGeneration: UInt64 = 0
    private var isShutdown = false

    init(loader: any ClipboardTokenizerLoading = ClipboardTokenizerLoader()) {
        self.loader = loader
    }
    func preload() async throws {
        _ = try await loadEncoder()
    }

    func countTokens(in text: String) async throws -> Int {
        try await countTokens(in: text, isCurrent: { true })
    }

    func countTokens(
        in text: String,
        isCurrent: @Sendable () -> Bool
    ) async throws -> Int {
        try checkCancellation(isCurrent)
        let encoder = try await loadEncoder()
        try checkCancellation(isCurrent)
        let count = encoder.encodeOrdinary(text).count
        try checkCancellation(isCurrent)
        return count
    }

    func shutdown() {
        isShutdown = true
        bootstrapGeneration &+= 1
        encoderTask?.cancel()
        encoderTask = nil
        encoder = nil
    }

    private func loadEncoder() async throws -> O200kBase {
        try Task.checkCancellation()
        guard !isShutdown else { throw CancellationError() }
        if let encoder { return encoder }
        if let encoderTask {
            let requestedGeneration = bootstrapGeneration
            do {
                let encoder = try await awaitEncoder(encoderTask)
                guard !isShutdown, bootstrapGeneration == requestedGeneration else {
                    throw CancellationError()
                }
                return encoder
            } catch {
                if bootstrapGeneration == requestedGeneration {
                    self.encoderTask = nil
                }
                throw error
            }
        }

        let loader = self.loader
        bootstrapGeneration &+= 1
        let requestedGeneration = bootstrapGeneration
        let task = Task { try await loader.load() }
        encoderTask = task
        do {
            let encoder = try await awaitEncoder(task)
            guard !isShutdown, bootstrapGeneration == requestedGeneration else {
                throw CancellationError()
            }
            self.encoder = encoder
            encoderTask = nil
            return encoder
        } catch {
            if bootstrapGeneration == requestedGeneration {
                encoderTask = nil
            }
            throw error
        }
    }

    private func awaitEncoder(_ task: Task<O200kBase, Error>) async throws -> O200kBase {
        try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    private func checkCancellation(_ isCurrent: @Sendable () -> Bool) throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
    }
}
