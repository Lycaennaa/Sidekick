import AppKit

enum PasteboardConditionalClearResult: Equatable {
    case cleared(changeCount: Int)
    case stale
    case unavailable
}

enum PasteboardConditionalArtifactDeletionResult: Equatable {
    case deleted
    case retained
    case stale
    case unavailable
}

@MainActor
struct PasteboardReplacementRequest {
    let expectedChangeCount: Int
    let expectedItems: [NSPasteboardItem]
    let replacementObjects: [NSPasteboardWriting]
    let rollbackItems: [NSPasteboardItem]?
    let configuration: PasteboardSnapshot.ContentMatchConfiguration
    let isStillOwned: @MainActor () async -> Bool
    let onMutation: (@MainActor (Int) -> Void)?
    let verify: (@MainActor () async -> Bool)?
}

@MainActor
protocol PasteboardOwnershipTransaction: AnyObject {
    /// Performs an optimistic transaction on the main actor. Implementations
    /// materialize and revalidate expected contents before synchronous mutation,
    /// verify installed contents, and roll back only while the mutation remains
    /// the current pasteboard generation.
    ///
    /// This is not atomic against external pasteboard clients: AppKit exposes no
    /// compare-and-swap. A detected newer generation must return `.stale` and
    /// must never be overwritten by rollback.
    func replaceContentsIfCurrent(
        request: PasteboardReplacementRequest
    ) async -> PasteboardSnapshot.ReplacementResult

    func clearContentsIfCurrent(
        expectedChangeCount: Int,
        matchingFileURL: URL,
        configuration: PasteboardSnapshot.FileURLConfiguration,
        isStillOwned: @escaping @MainActor () -> Bool
    ) async -> PasteboardConditionalClearResult

    func deleteFileIfUnreferenced(
        _ url: URL,
        expectedChangeCount: Int,
        configuration: PasteboardSnapshot.FileURLConfiguration,
        isStillOwned: @escaping @MainActor () -> Bool,
        removeItem: @escaping @MainActor (URL) throws -> Void
    ) async -> PasteboardConditionalArtifactDeletionResult

}
@MainActor
final class PasteboardTransactionCoordinator: PasteboardOwnershipTransaction {
    private let pasteboard: any PasteboardAccess

    init(pasteboard: any PasteboardAccess) {
        self.pasteboard = pasteboard
    }

    func replaceContentsIfCurrent(
        request: PasteboardReplacementRequest
    ) async -> PasteboardSnapshot.ReplacementResult {
        let replacementItems = request.replacementObjects.compactMap { $0 as? NSPasteboardItem }
        guard replacementItems.count == request.replacementObjects.count else { return .stale }
        guard await isCurrent(request) else { return .stale }

        let mutationChangeCount = pasteboard.clearContents()
        guard pasteboard.changeCount == mutationChangeCount else { return .stale }
        request.onMutation?(mutationChangeCount)
        return await writeAndVerify(
            request,
            replacementItems: replacementItems,
            mutationChangeCount: mutationChangeCount
        )
    }

    private func isCurrent(_ request: PasteboardReplacementRequest) async -> Bool {
        guard !Task.isCancelled,
              pasteboard.changeCount == request.expectedChangeCount else {
            return false
        }
        guard await matchesContents(
            expectedItems: request.expectedItems,
            configuration: request.configuration
        ) else {
            return false
        }
        guard !Task.isCancelled,
              pasteboard.changeCount == request.expectedChangeCount else {
            return false
        }
        guard await request.isStillOwned(),
              !Task.isCancelled,
              pasteboard.changeCount == request.expectedChangeCount else {
            return false
        }
        return true
    }

    private func writeAndVerify(
        _ request: PasteboardReplacementRequest,
        replacementItems: [NSPasteboardItem],
        mutationChangeCount: Int
    ) async -> PasteboardSnapshot.ReplacementResult {
        guard pasteboard.writeObjects(request.replacementObjects) else {
            return await rollbackIgnoringCancellation(
                request.rollbackItems,
                mutationChangeCount: mutationChangeCount,
                configuration: request.configuration
            )
        }
        guard pasteboard.changeCount == mutationChangeCount else { return .stale }

        let installedMatches = await matchesContents(
            expectedItems: replacementItems,
            configuration: request.configuration
        )
        guard pasteboard.changeCount == mutationChangeCount else { return .stale }
        guard installedMatches, !Task.isCancelled else {
            return await rollbackIgnoringCancellation(
                request.rollbackItems,
                mutationChangeCount: mutationChangeCount,
                configuration: request.configuration
            )
        }

        if let verify = request.verify {
            let verified = await verify()
            guard pasteboard.changeCount == mutationChangeCount else { return .stale }
            guard verified, !Task.isCancelled else {
                return await rollbackIgnoringCancellation(
                    request.rollbackItems,
                    mutationChangeCount: mutationChangeCount,
                    configuration: request.configuration
                )
            }
        }
        return .installed(changeCount: mutationChangeCount)
    }

    func clearContentsIfCurrent(
        expectedChangeCount: Int,
        matchingFileURL: URL,
        configuration: PasteboardSnapshot.FileURLConfiguration,
        isStillOwned: @escaping @MainActor () -> Bool
    ) async -> PasteboardConditionalClearResult {
        let standardizedURL = matchingFileURL.standardizedFileURL
        guard !Task.isCancelled,
              pasteboard.changeCount == expectedChangeCount else {
            return .stale
        }
        guard await PasteboardSnapshot.exactFileURL(
            from: pasteboard,
            maximumItems: configuration.maximumItems,
            maximumTypesPerItem: configuration.maximumTypesPerItem,
            expectedChangeCount: expectedChangeCount,
            maximumReadDuration: configuration.maximumReadDuration,
            fileURLReader: configuration.fileURLReader
        ) == standardizedURL else {
            return .stale
        }
        guard !Task.isCancelled,
              pasteboard.changeCount == expectedChangeCount,
              isStillOwned() else {
            return .stale
        }
        guard await PasteboardSnapshot.exactFileURL(
            from: pasteboard,
            maximumItems: configuration.maximumItems,
            maximumTypesPerItem: configuration.maximumTypesPerItem,
            expectedChangeCount: expectedChangeCount,
            maximumReadDuration: configuration.maximumReadDuration,
            fileURLReader: configuration.fileURLReader
        ) == standardizedURL else {
            return .stale
        }
        guard !Task.isCancelled,
              pasteboard.changeCount == expectedChangeCount,
              isStillOwned() else {
            return .stale
        }

        let clearedChangeCount = pasteboard.clearContents()
        guard !Task.isCancelled,
              pasteboard.changeCount == clearedChangeCount,
              pasteboard.pasteboardItems?.isEmpty != false else {
            return .stale
        }
        return .cleared(changeCount: clearedChangeCount)
    }

    private func matchesContents(
        expectedItems: [NSPasteboardItem],
        configuration: PasteboardSnapshot.ContentMatchConfiguration
    ) async -> Bool {
        // Live provider reads verify current content against the captured rollback data.
        // The snapshot is the expected value, not evidence that the clipboard still matches it.
        await PasteboardSnapshot.contentsMatch(
            currentItems: pasteboard.pasteboardItems,
            expectedItems: expectedItems,
            configuration: configuration
        )
    }

    private func rollback(
        _ rollbackItems: [NSPasteboardItem]?,
        mutationChangeCount: Int,
        configuration: PasteboardSnapshot.ContentMatchConfiguration
    ) async -> PasteboardSnapshot.ReplacementResult {
        guard let rollbackItems else { return .restoreFailed }
        guard pasteboard.changeCount == mutationChangeCount else { return .stale }

        let rollbackChangeCount = pasteboard.clearContents()
        guard pasteboard.changeCount == rollbackChangeCount else { return .stale }
        if !rollbackItems.isEmpty, !pasteboard.writeObjects(rollbackItems) {
            return pasteboard.changeCount == rollbackChangeCount ? .restoreFailed : .stale
        }
        guard pasteboard.changeCount == rollbackChangeCount else { return .stale }

        let restoredMatches = await matchesContents(
            expectedItems: rollbackItems,
            configuration: configuration
        )
        guard pasteboard.changeCount == rollbackChangeCount else { return .stale }
        guard restoredMatches else { return .restoreFailed }
        return .failed(restoredChangeCount: rollbackChangeCount)
    }
    private func rollbackIgnoringCancellation(
        _ rollbackItems: [NSPasteboardItem]?,
        mutationChangeCount: Int,
        configuration: PasteboardSnapshot.ContentMatchConfiguration
    ) async -> PasteboardSnapshot.ReplacementResult {
        let rollbackTask = Task { @MainActor in
            await rollback(
                rollbackItems,
                mutationChangeCount: mutationChangeCount,
                configuration: configuration
            )
        }
        return await rollbackTask.value
    }

    func deleteFileIfUnreferenced(
        _ url: URL,
        expectedChangeCount: Int,
        configuration: PasteboardSnapshot.FileURLConfiguration,
        isStillOwned: @escaping @MainActor () -> Bool,
        removeItem: @escaping @MainActor (URL) throws -> Void
    ) async -> PasteboardConditionalArtifactDeletionResult {
        let standardizedURL = url.standardizedFileURL
        guard !Task.isCancelled, pasteboard.changeCount == expectedChangeCount else { return .stale }
        guard let referencedURLs = await PasteboardSnapshot.boundedFileURLs(
            from: pasteboard,
            maximumItems: configuration.maximumItems,
            maximumTypesPerItem: configuration.maximumTypesPerItem,
            expectedChangeCount: expectedChangeCount,
            maximumReadDuration: configuration.maximumReadDuration,
            fileURLReader: configuration.fileURLReader
        ) else {
            return .retained
        }
        guard !Task.isCancelled, !referencedURLs.contains(standardizedURL) else {
            return .retained
        }

        guard !Task.isCancelled,
              isStillOwned(),
              pasteboard.changeCount == expectedChangeCount else {
            return .stale
        }
        guard let revalidatedURLs = await PasteboardSnapshot.boundedFileURLs(
            from: pasteboard,
            maximumItems: configuration.maximumItems,
            maximumTypesPerItem: configuration.maximumTypesPerItem,
            expectedChangeCount: expectedChangeCount,
            maximumReadDuration: configuration.maximumReadDuration,
            fileURLReader: configuration.fileURLReader
        ) else {
            return .retained
        }
        guard !Task.isCancelled else { return .retained }
        guard !revalidatedURLs.contains(standardizedURL) else { return .retained }
        guard isStillOwned(), pasteboard.changeCount == expectedChangeCount else { return .stale }

        do {
            try removeItem(url)
            return .deleted
        } catch {
            return .retained
        }
    }
}

@MainActor
extension NSPasteboard: PasteboardOwnershipTransaction {
    func replaceContentsIfCurrent(
        request: PasteboardReplacementRequest
    ) async -> PasteboardSnapshot.ReplacementResult {
        await PasteboardTransactionCoordinator(pasteboard: self).replaceContentsIfCurrent(
            request: request
        )
    }

    func clearContentsIfCurrent(
        expectedChangeCount: Int,
        matchingFileURL: URL,
        configuration: PasteboardSnapshot.FileURLConfiguration,
        isStillOwned: @escaping @MainActor () -> Bool
    ) async -> PasteboardConditionalClearResult {
        await PasteboardTransactionCoordinator(pasteboard: self).clearContentsIfCurrent(
            expectedChangeCount: expectedChangeCount,
            matchingFileURL: matchingFileURL,
            configuration: configuration,
            isStillOwned: isStillOwned
        )
    }

    func deleteFileIfUnreferenced(
        _ url: URL,
        expectedChangeCount: Int,
        configuration: PasteboardSnapshot.FileURLConfiguration,
        isStillOwned: @escaping @MainActor () -> Bool,
        removeItem: @escaping @MainActor (URL) throws -> Void
    ) async -> PasteboardConditionalArtifactDeletionResult {
        await PasteboardTransactionCoordinator(pasteboard: self).deleteFileIfUnreferenced(
            url,
            expectedChangeCount: expectedChangeCount,
            configuration: configuration,
            isStillOwned: isStillOwned,
            removeItem: removeItem
        )
    }
}

@MainActor
extension PasteboardSnapshot {
    func replace(
        pasteboard: any PasteboardAccess,
        expectedChangeCount: Int,
        with objects: [NSPasteboardWriting],
        maximumBytes: Int = 16 * 1_024 * 1_024,
        maximumTypesPerItem: Int = PasteboardSnapshotPolicy.maximumTypesPerItem,
        fileURLReader: any PasteboardFileURLReading = SystemPasteboardFileURLReader(),
        payloadReader: any PasteboardPayloadReading = SystemPasteboardPayloadReader(),
        isStillOwned: @escaping @MainActor () async -> Bool = { true },
        onMutation: (@MainActor (Int) -> Void)? = nil,
        verify: (@MainActor () async -> Bool)? = nil
    ) async -> ReplacementResult {
        guard let transaction = pasteboard as? any PasteboardOwnershipTransaction else {
            return .stale
        }
        let configuration = PasteboardSnapshot.ContentMatchConfiguration(
            maximumBytes: maximumBytes,
            maximumTypesPerItem: maximumTypesPerItem,
            fileURLReader: fileURLReader,
            payloadReader: payloadReader
        )
        let request = PasteboardReplacementRequest(
            expectedChangeCount: expectedChangeCount,
            expectedItems: items,
            replacementObjects: objects,
            rollbackItems: items,
            configuration: configuration,
            isStillOwned: isStillOwned,
            onMutation: onMutation,
            verify: verify
        )
        switch await transaction.replaceContentsIfCurrent(request: request) {
        case let .installed(changeCount):
            guard pasteboard.changeCount == changeCount else { return .stale }
            return .installed(changeCount: changeCount)
        case let .failed(restoredChangeCount):
            return pasteboard.changeCount == restoredChangeCount
                ? .failed(restoredChangeCount: restoredChangeCount)
                : .stale
        case .restoreFailed:
            return .restoreFailed
        case .stale:
            return .stale
        }
    }

}
