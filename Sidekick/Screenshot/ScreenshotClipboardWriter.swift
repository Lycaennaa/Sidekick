import AppKit

@MainActor
final class ScreenshotClipboardWriter {
    enum Failure {
        case changed
        case snapshot
        case restore
    }

    enum Result {
        case installed(changeCount: Int)
        case cancelled
        case failed(Failure)
        case failedButRestored(changeCount: Int)
    }

    private static let snapshotLimits = PasteboardSnapshot.Limits(
        maximumBytes: PasteboardSnapshotPolicy.maximumBytes,
        maximumItems: PasteboardSnapshotPolicy.maximumItems,
        maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem
    )

    private let pasteboard: any PasteboardAccess
    private let metadataRegistry: ScreenshotClipboardMetadataRegistry
    private let payloadReader: any PasteboardPayloadReading
    private var pendingMutationIDs = Set<UUID>()

    var changeCount: Int { pasteboard.changeCount }
    var hasPendingMutation: Bool { !pendingMutationIDs.isEmpty }

    init(
        pasteboard: any PasteboardAccess = NSPasteboard.general,
        metadataRegistry: ScreenshotClipboardMetadataRegistry,
        payloadReader: any PasteboardPayloadReading = SystemPasteboardPayloadReader()
    ) {
        self.pasteboard = pasteboard
        self.metadataRegistry = metadataRegistry
        self.payloadReader = payloadReader
    }

    func replace(
        with item: NSPasteboardItem,
        isScreenshot: Bool,
        expectedChangeCount: Int,
        isCurrentRequest: @escaping @MainActor () async -> Bool
    ) async -> Result {
        guard await isCurrentRequest(), !Task.isCancelled else { return .cancelled }
        guard pasteboard.changeCount == expectedChangeCount else { return .failed(.changed) }
        let capture = await PasteboardSnapshot.capture(
            from: pasteboard,
            expectedChangeCount: expectedChangeCount,
            limits: Self.snapshotLimits,
            payloadReader: payloadReader
        )
        guard await isCurrentRequest(), !Task.isCancelled else { return .cancelled }
        guard pasteboard.changeCount == expectedChangeCount else { return .failed(.changed) }

        let snapshot: PasteboardSnapshot
        switch capture {
        case let .captured(value):
            snapshot = value
        case .stale:
            return .failed(.changed)
        case .failed:
            return .failed(.snapshot)
        }

        let mutationID = UUID()
        let replacement = await snapshot.replace(
            pasteboard: pasteboard,
            expectedChangeCount: expectedChangeCount,
            with: [item],
            maximumBytes: Self.snapshotLimits.maximumBytes,
            maximumTypesPerItem: Self.snapshotLimits.maximumTypesPerItem,
            payloadReader: payloadReader,
            isStillOwned: isCurrentRequest,
            onMutation: { [self] changeCount in
                pendingMutationIDs.insert(mutationID)
                if isScreenshot {
                    metadataRegistry.register(.sdr, forChangeCount: changeCount)
                }
            },
            verify: isCurrentRequest
        )
        let isCurrent = await isCurrentRequest()
        let isCancelled = Task.isCancelled
        let result = clipboardReplacement(from: replacement)
        pendingMutationIDs.remove(mutationID)
        guard isCurrent, !isCancelled else { return .cancelled }
        return result
    }

    private func clipboardReplacement(
        from result: PasteboardSnapshot.ReplacementResult
    ) -> Result {
        switch result {
        case let .installed(changeCount):
            guard pasteboard.changeCount == changeCount else { return .failed(.changed) }
            return .installed(changeCount: changeCount)
        case .stale:
            return .failed(.changed)
        case let .failed(restoredChangeCount):
            guard pasteboard.changeCount == restoredChangeCount else { return .failed(.changed) }
            return .failedButRestored(changeCount: restoredChangeCount)
        case .restoreFailed:
            return .failed(.restore)
        }
    }
}
