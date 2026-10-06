import Foundation
import TiktokenSwiftPort

func makeTestO200kBase() throws -> O200kBase {
    var encoder: [Data: UInt32] = [:]
    for value in 0...255 {
        encoder[Data([UInt8(value)])] = UInt32(value)
    }
    return try O200kBase(mergeableRanks: encoder)
}

final class ControlledTokenizerLoader: ClipboardTokenizerLoading, @unchecked Sendable {
    let state = TokenizerLoadState()
    private let encoder: O200kBase

    init(encoder: O200kBase) {
        self.encoder = encoder
    }

    func load() async -> O200kBase {
        await state.recordStart()
        await state.waitForRelease()
        return encoder
    }
}

final class BlockingTokenizerLoader: ClipboardTokenizerLoading, @unchecked Sendable {
    let state = TokenizerLoadState()

    func load() async throws -> O200kBase {
        await state.recordStart()
        do {
            try await Task.sleep(nanoseconds: UInt64.max)
        } catch {
            await state.recordCancellation()
            throw error
        }
        fatalError("Blocking tokenizer loader was not cancelled")
    }
}

actor TokenizerLoadState {
    private(set) var loadCount = 0
    private var started = false
    private var released = false
    private var cancelled = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var cancellationContinuation: CheckedContinuation<Void, Never>?

    func recordStart() {
        loadCount += 1
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func recordCancellation() {
        cancelled = true
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }

    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { cancellationContinuation = $0 }
    }
}
