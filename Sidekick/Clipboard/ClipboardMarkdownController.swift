import AppKit

nonisolated struct ClipboardMarkdownMetrics: Equatable, Sendable {
    let before: ClipboardTextMetrics?
    let after: ClipboardTextMetrics?
}

@MainActor
final class ClipboardMarkdownController {
    enum Result: Equatable {
        case cleaned(changeCount: Int, metrics: ClipboardMarkdownMetrics)
        case noText
        case unavailable
        case tooLarge
        case stale
        case cancelled
        case failed
        case restoreFailed
    }

    static let maximumInputBytes = 1 * 1_024 * 1_024
    private static let snapshotLimits = PasteboardSnapshot.Limits(
        maximumBytes: 16 * 1_024 * 1_024,
        maximumItems: PasteboardSnapshot.defaultMaximumItems,
        maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem
    )

    typealias Cleaner = @Sendable (String) async throws -> String

    private let pasteboard: any PasteboardAccess
    private let cleaner: Cleaner
    private let payloadReader: any PasteboardPayloadReading
    private let tokenizer: ClipboardTokenizer

    private var cleaningTask: Task<Void, Never>?
    private var cleaningGeneration: UInt64 = 0
    private var isTerminated = false

    init(
        pasteboard: any PasteboardAccess = NSPasteboard.general,
        cleaner: @escaping Cleaner = { MarkdownTextCleaner.clean($0) },
        payloadReader: any PasteboardPayloadReading = SystemPasteboardPayloadReader(),
        tokenizer: ClipboardTokenizer = ClipboardTokenizer()
    ) {
        self.pasteboard = pasteboard
        self.cleaner = cleaner
        self.payloadReader = payloadReader
        self.tokenizer = tokenizer
    }

    private nonisolated static func runCleaner(
        _ markdown: String,
        cleaner: @escaping Cleaner
    ) async throws -> String {
        let task: Task<String, Error> = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let cleaned = try await cleaner(markdown)
            try Task.checkCancellation()
            return cleaned
        }
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    func requestCleaning(completion: @escaping (Result) -> Void) {
        guard !isTerminated else { return }
        cleaningTask?.cancel()
        cleaningGeneration &+= 1
        let requestGeneration = cleaningGeneration
        cleaningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.cleanClipboard()
            guard !Task.isCancelled,
                  !self.isTerminated,
                  self.cleaningGeneration == requestGeneration else {
                return
            }
            completion(result)
            if self.cleaningGeneration == requestGeneration {
                self.cleaningTask = nil
            }
        }
    }

    func cancelPendingCleaning() {
        cleaningGeneration &+= 1
        cleaningTask?.cancel()
        cleaningTask = nil
    }

    func terminate() {
        guard !isTerminated else { return }
        isTerminated = true
        cancelPendingCleaning()
    }

    func cleanClipboard() async -> Result {
        guard !Task.isCancelled else { return .cancelled }
        let sourceChangeCount = pasteboard.changeCount
        guard let sourceItems = PasteboardSnapshot.boundedItems(
            from: pasteboard,
            maximumItems: Self.snapshotLimits.maximumItems,
            rejectingOverflow: true
        ) else {
            guard !Task.isCancelled else { return .cancelled }
            return pasteboard.changeCount == sourceChangeCount ? .tooLarge : .stale
        }

        switch await prepareReplacement(
            sourceItems: sourceItems,
            sourceChangeCount: sourceChangeCount
        ) {
        case let .terminal(result):
            return result
        case let .ready(snapshot, replacementItem, beforeMetrics, afterMetrics):
            guard !Task.isCancelled else { return .cancelled }
            switch await replace(
                snapshot: snapshot,
                replacementItem: replacementItem,
                sourceChangeCount: sourceChangeCount
            ) {
            case let .installed(changeCount):
                return .cleaned(
                    changeCount: changeCount,
                    metrics: ClipboardMarkdownMetrics(
                        before: beforeMetrics,
                        after: afterMetrics
                    )
                )
            case .stale:
                return .stale
            case .failed:
                return .failed
            case .restoreFailed:
                return .restoreFailed
            }
        }
    }
}
extension ClipboardMarkdownController {
    private enum ReadResult {
        case text(String)
        case terminal(Result)
    }

    private enum CleanResult {
        case cleaned(
            text: String,
            beforeMetrics: ClipboardTextMetrics?,
            afterMetrics: ClipboardTextMetrics?
        )
        case terminal(Result)
    }

    private enum SnapshotResult {
        case captured(PasteboardSnapshot)
        case terminal(Result)
    }

    private enum PreparationResult {
        case ready(
            snapshot: PasteboardSnapshot,
            replacementItem: NSPasteboardItem,
            beforeMetrics: ClipboardTextMetrics?,
            afterMetrics: ClipboardTextMetrics?
        )
        case terminal(Result)
    }

    private func prepareReplacement(
        sourceItems: [NSPasteboardItem],
        sourceChangeCount: Int
    ) async -> PreparationResult {
        switch await readMarkdown(from: sourceItems) {
        case let .terminal(result):
            return .terminal(result)
        case let .text(markdown):
            switch await cleanMarkdown(markdown) {
            case let .terminal(result):
                return .terminal(result)
            case let .cleaned(text, beforeMetrics, afterMetrics):
                switch await captureSnapshot(expectedChangeCount: sourceChangeCount) {
                case let .terminal(result):
                    return .terminal(result)
                case let .captured(snapshot):
                    guard !Task.isCancelled else { return .terminal(.cancelled) }
                    let replacementItem = NSPasteboardItem()
                    guard replacementItem.setString(text, forType: .string) else {
                        return .terminal(.failed)
                    }
                    return .ready(
                        snapshot: snapshot,
                        replacementItem: replacementItem,
                        beforeMetrics: beforeMetrics,
                        afterMetrics: afterMetrics
                    )
                }
            }
        }
    }

    private func readMarkdown(from sourceItems: [NSPasteboardItem]) async -> ReadResult {
        let readResult = await PasteboardPayloadReader.readData(
            from: sourceItems,
            forType: .string,
            maximumBytes: Self.maximumInputBytes,
            payloadReader: payloadReader
        )
        guard !Task.isCancelled else { return .terminal(.cancelled) }
        switch readResult {
        case .missing:
            return .terminal(.noText)
        case .timedOut, .failed, .unavailable:
            return .terminal(.unavailable)
        case .cancelled:
            return .terminal(.cancelled)
        case .tooLarge:
            return .terminal(.tooLarge)
        case let .data(data):
            guard let markdown = PasteboardPayloadReader.string(from: data) else {
                return .terminal(.noText)
            }
            return .text(markdown)
        }
    }

    private func cleanMarkdown(_ markdown: String) async -> CleanResult {
        let beforeMetrics = await ClipboardTextMetrics.count(in: markdown, using: tokenizer)
        guard !Task.isCancelled else { return .terminal(.cancelled) }

        let cleaned: String
        do {
            cleaned = try await Self.runCleaner(markdown, cleaner: cleaner)
        } catch is CancellationError {
            return .terminal(.cancelled)
        } catch {
            return .terminal(Task.isCancelled ? .cancelled : .failed)
        }
        guard !Task.isCancelled else { return .terminal(.cancelled) }

        let afterMetrics = await ClipboardTextMetrics.count(in: cleaned, using: tokenizer)
        guard !Task.isCancelled else { return .terminal(.cancelled) }
        return .cleaned(
            text: cleaned,
            beforeMetrics: beforeMetrics,
            afterMetrics: afterMetrics
        )
    }

    private func captureSnapshot(expectedChangeCount: Int) async -> SnapshotResult {
        switch await PasteboardSnapshot.capture(
            from: pasteboard,
            expectedChangeCount: expectedChangeCount,
            limits: Self.snapshotLimits,
            payloadReader: payloadReader
        ) {
        case let .captured(snapshot):
            return .captured(snapshot)
        case .stale:
            return .terminal(Task.isCancelled ? .cancelled : .stale)
        case .failed:
            return .terminal(Task.isCancelled ? .cancelled : .failed)
        }
    }

    private func replace(
        snapshot: PasteboardSnapshot,
        replacementItem: NSPasteboardItem,
        sourceChangeCount: Int
    ) async -> PasteboardSnapshot.ReplacementResult {
        await snapshot.replace(
            pasteboard: pasteboard,
            expectedChangeCount: sourceChangeCount,
            with: [replacementItem],
            maximumBytes: Self.snapshotLimits.maximumBytes,
            maximumTypesPerItem: Self.snapshotLimits.maximumTypesPerItem,
            payloadReader: payloadReader,
            verify: {
                guard let item = self.pasteboard.pasteboardItems?.first,
                      case let .data(data) = await self.payloadReader.readData(
                          from: item,
                          forType: .string,
                          maximumBytes: Self.snapshotLimits.maximumBytes
                      ) else {
                    return false
                }
                return PasteboardPayloadReader.string(from: data) == replacementItem.string(
                    forType: .string
                )
            }
        )
    }
}
