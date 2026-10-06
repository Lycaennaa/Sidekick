import AppKit
enum ClipboardClearURLsResult: Equatable {
    case cleaned(changeCount: Int)
    case unchanged
    case noText
    case stale
    case failed
    case replacementFailed(restoredChangeCount: Int)
    case restoreFailed
}

@MainActor
final class ClipboardClearURLsController {
    static let pollInterval = ClipboardToastController.pollInterval

    private static let snapshotLimits = PasteboardSnapshot.Limits(
        maximumBytes: 16 * 1_024 * 1_024,
        maximumItems: PasteboardSnapshot.defaultMaximumItems,
        maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem
    )

    private struct TransformedSnapshot {
        let items: [NSPasteboardItem]
        let containsText: Bool
        let changed: Bool
    }

    private let settings: AppSettings
    private let pasteboard: any PasteboardAccess
    private let cleaner: ClearURLsURLCleaner
    private let fileURLReader: any PasteboardFileURLReading
    private let payloadReader: any PasteboardPayloadReading
    private let onResult: (ClipboardClearURLsResult) -> Void

    private var pollTimer: Timer?
    private var cleaningTask: Task<Void, Never>?
    private var observation = ClipboardChangeObservationState()
    private var started = false
    private var isTerminated = false
    private var isSuspended = false
    private var mutationGeneration: UInt64 = 0

    init(
        settings: AppSettings,
        pasteboard: any PasteboardAccess = NSPasteboard.general,
        rules: ClearURLsRuleSet? = nil,
        bundle: Bundle = .main,
        fileURLReader: any PasteboardFileURLReading = SystemPasteboardFileURLReader(),
        payloadReader: any PasteboardPayloadReading = SystemPasteboardPayloadReader(),
        onResult: @escaping (ClipboardClearURLsResult) -> Void
    ) throws {
        self.settings = settings
        self.pasteboard = pasteboard
        self.cleaner = ClearURLsURLCleaner(
            ruleSet: try rules ?? ClearURLsRuleSet.loadBundled(from: bundle)
        )
        self.fileURLReader = fileURLReader
        self.payloadReader = payloadReader
        self.onResult = onResult
    }

    func start() {
        guard !started, !isTerminated, settings.clearURLsClipboardEnabled else { return }
        started = true
        observation.invalidate()
        startPollTimer()
        poll()
    }

    func applySettings() {
        guard !isTerminated else { return }
        if settings.clearURLsClipboardEnabled {
            if !started { start() }
        } else {
            stopMonitoring()
        }
    }

    func beginClipboardMutation() -> UInt64 {
        mutationGeneration &+= 1
        guard started, !isTerminated else { return mutationGeneration }
        isSuspended = true
        cancelCleaning()
        observation.invalidate()
        return mutationGeneration
    }

    func endClipboardMutation(_ generation: UInt64) {
        guard generation == mutationGeneration,
              started,
              !isTerminated,
              settings.clearURLsClipboardEnabled else {
            return
        }
        isSuspended = false
        observation.rearm(changeCount: pasteboard.changeCount)
    }

    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        stopMonitoring()
    }

    func poll() {
        guard started, !isSuspended, !isTerminated, settings.clearURLsClipboardEnabled else { return }
        let currentChangeCount = pasteboard.changeCount
        let previousChangeCount = observation.observedChangeCount
        let generation = observation.observe(changeCount: currentChangeCount)
        if previousChangeCount != currentChangeCount {
            cancelCleaning()
            return
        }
        guard let generation else { return }
        beginCleaning(
            expectedChangeCount: currentChangeCount,
            generation: generation
        )
    }

    private func startPollTimer() {
        guard pollTimer == nil else { return }
        let timer = Timer(
            timeInterval: Self.pollInterval,
            target: self,
            selector: #selector(pollTimerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopMonitoring() {
        started = false
        isSuspended = false
        mutationGeneration &+= 1
        cancelCleaning()
        observation.invalidate()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func cancelCleaning() {
        cleaningTask?.cancel()
        cleaningTask = nil
    }

    private func beginCleaning(expectedChangeCount: Int, generation: UInt64) {
        cancelCleaning()
        cleaningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.clean(
                expectedChangeCount: expectedChangeCount,
                generation: generation
            )
            guard !Task.isCancelled,
                  !self.isTerminated,
                  self.started,
                  self.settings.clearURLsClipboardEnabled,
                  self.isCurrentGeneration(generation) else {
                return
            }
            self.cleaningTask = nil
            switch result {
            case let .cleaned(changeCount):
                guard self.pasteboard.changeCount == changeCount else { return }
                self.observation.seed(changeCount: changeCount)
            case let .replacementFailed(restoredChangeCount):
                guard self.pasteboard.changeCount == restoredChangeCount else { return }
                self.observation.seed(changeCount: restoredChangeCount)
            case .failed, .restoreFailed, .unchanged, .noText, .stale:
                break
            }
            self.onResult(result)
        }
    }

    private func clean(
        expectedChangeCount: Int,
        generation: UInt64
    ) async -> ClipboardClearURLsResult {
        switch await captureForCleaning(
            expectedChangeCount: expectedChangeCount,
            generation: generation
        ) {
        case let .result(result):
            return result
        case let .captured(snapshot):
            guard isCurrent(
                expectedChangeCount: expectedChangeCount,
                generation: generation
            ) else {
                return .stale
            }
            guard let transformed = transformedSnapshot(snapshot) else { return .failed }
            guard transformed.containsText else { return .noText }
            guard transformed.changed else { return .unchanged }
            guard isCurrent(
                expectedChangeCount: expectedChangeCount,
                generation: generation
            ) else {
                return .stale
            }
            let replacementResult = await replaceSnapshot(
                snapshot: snapshot,
                items: transformed.items,
                expectedChangeCount: expectedChangeCount
            )
            return result(for: replacementResult, generation: generation)
        }
    }

    private func transformedSnapshot(
        _ snapshot: PasteboardSnapshot
    ) -> TransformedSnapshot? {
        var replacementItems: [NSPasteboardItem] = []
        replacementItems.reserveCapacity(snapshot.items.count)
        var containsText = false
        var changed = false

        for sourceItem in snapshot.items {
            let replacementItem = NSPasteboardItem()
            for type in sourceItem.types {
                guard let sourceData = sourceItem.data(forType: type) else { return nil }
                var replacementData = sourceData
                if type == .string || type == .URL {
                    containsText = true
                    if let text = PasteboardPayloadReader.string(from: sourceData) {
                        let cleaned = cleaner.clean(text)
                        if cleaned != text {
                            replacementData = Data(cleaned.utf8)
                            changed = true
                        }
                    }
                }
                guard replacementItem.setData(replacementData, forType: type) else {
                    return nil
                }
            }
            replacementItems.append(replacementItem)
        }

        return TransformedSnapshot(
            items: replacementItems,
            containsText: containsText,
            changed: changed
        )
    }

    private func isCurrent(
        expectedChangeCount: Int,
        generation: UInt64
    ) -> Bool {
        !Task.isCancelled
            && !isTerminated
            && started
            && !isSuspended
            && settings.clearURLsClipboardEnabled
            && observation.isCurrentGeneration(generation)
            && pasteboard.changeCount == expectedChangeCount
    }

    private func isCurrentGeneration(_ generation: UInt64) -> Bool {
        !Task.isCancelled
            && !isTerminated
            && started
            && !isSuspended
            && observation.isCurrentGeneration(generation)
    }

    @objc private func pollTimerFired() {
        poll()
    }
}
extension ClipboardClearURLsController {
    private enum CleanCaptureResult {
        case captured(PasteboardSnapshot)
        case result(ClipboardClearURLsResult)
    }

    private func captureForCleaning(
        expectedChangeCount: Int,
        generation: UInt64
    ) async -> CleanCaptureResult {
        guard isCurrent(
            expectedChangeCount: expectedChangeCount,
            generation: generation
        ) else {
            return .result(.stale)
        }
        let captureResult = await PasteboardSnapshot.capture(
            from: pasteboard,
            expectedChangeCount: expectedChangeCount,
            limits: Self.snapshotLimits,
            fileURLReader: fileURLReader,
            payloadReader: payloadReader
        )
        guard isCurrent(
            expectedChangeCount: expectedChangeCount,
            generation: generation
        ) else {
            return .result(.stale)
        }
        switch captureResult {
        case let .captured(snapshot):
            return .captured(snapshot)
        case .stale:
            return .result(.stale)
        case .failed:
            return .result(.failed)
        }
    }

    private func replaceSnapshot(
        snapshot: PasteboardSnapshot,
        items: [NSPasteboardItem],
        expectedChangeCount: Int
    ) async -> PasteboardSnapshot.ReplacementResult {
        await snapshot.replace(
            pasteboard: pasteboard,
            expectedChangeCount: expectedChangeCount,
            with: items,
            maximumBytes: Self.snapshotLimits.maximumBytes,
            maximumTypesPerItem: Self.snapshotLimits.maximumTypesPerItem,
            fileURLReader: fileURLReader,
            payloadReader: payloadReader
        )
    }

    private func result(
        for replacementResult: PasteboardSnapshot.ReplacementResult,
        generation: UInt64
    ) -> ClipboardClearURLsResult {
        guard isCurrentGeneration(generation) else { return .stale }
        switch replacementResult {
        case let .installed(changeCount):
            guard pasteboard.changeCount == changeCount else { return .stale }
            return .cleaned(changeCount: changeCount)
        case .stale:
            return .stale
        case let .failed(restoredChangeCount):
            return .replacementFailed(restoredChangeCount: restoredChangeCount)
        case .restoreFailed:
            return .restoreFailed
        }
    }
}
