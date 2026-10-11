import AppKit

@MainActor
final class ClipboardWebPController {
    enum Result: Equatable {
        case converted(URL)
        case alreadyWebP
        case noImage
        case unavailable
        case failed
        case stale
        case cancelled
    }

    private static let snapshotLimits = PasteboardSnapshot.Limits(
        maximumBytes: PasteboardSnapshotPolicy.maximumBytes,
        maximumItems: PasteboardSnapshotPolicy.maximumItems,
        maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem
    )

    private let pasteboard: any PasteboardAccess
    private let artifactOwner: ClipboardWebPArtifactOwner
    private let onConverted: (URL, Int) -> Void
    private let onMessage: (String) -> Void
    private let worker: ClipboardWebPWorker
    private let fileURLReader: any PasteboardFileURLReading
    private let payloadReader: any PasteboardPayloadReading

    private var token: UInt64 = 0
    private var captureTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var terminationCleanupTask: Task<Void, Never>?
    private var terminated = false

    init(
        pasteboard: any PasteboardAccess = NSPasteboard.general,
        expirationInterval: TimeInterval = 60,
        outputDirectory: URL = ClipboardWebPConfiguration.defaultOutputDirectory,
        worker: ClipboardWebPWorker = ClipboardWebPWorker(),
        fileURLReader: any PasteboardFileURLReading = SystemPasteboardFileURLReader(),
        payloadReader: any PasteboardPayloadReading = SystemPasteboardPayloadReader(),
        onConverted: @escaping (URL, Int) -> Void = { _, _ in },
        onMessage: @escaping (String) -> Void
    ) {
        self.pasteboard = pasteboard
        self.onConverted = onConverted
        self.onMessage = onMessage
        self.worker = worker
        self.fileURLReader = fileURLReader
        self.payloadReader = payloadReader
        artifactOwner = ClipboardWebPArtifactOwner(
            expirationInterval: expirationInterval,
            outputDirectory: outputDirectory,
            pasteboard: pasteboard,
            fileURLReader: fileURLReader,
            onMessage: onMessage,
            currentGeneration: { pasteboard.changeCount }
        )
        artifactOwner.onExpired = { [weak self] lease in
            await self?.expire(lease)
        }
    }

    func convertClipboardImage(
        skipAlreadyWebPFiles: Bool = false,
        completion: @escaping (Result) -> Void = { _ in }
    ) {
        guard !terminated else {
            completion(.cancelled)
            return
        }
        token &+= 1
        captureTask?.cancel()
        installTask?.cancel()
        worker.cancelAll()
        let requestToken = token
        let pasteboard = self.pasteboard
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.captureAndEnqueue(
                pasteboard: pasteboard,
                requestToken: requestToken,
                skipAlreadyWebPFiles: skipAlreadyWebPFiles,
                completion: completion
            )
        }
    }

    func terminate() {
        guard !terminated else { return }
        terminated = true
        token &+= 1
        captureTask?.cancel()
        installTask?.cancel()
        captureTask = nil
        installTask = nil
        worker.cancelAll()
        let lease = artifactOwner.currentLease
        guard let lease else {
            artifactOwner.terminate()
            return
        }
        artifactOwner.terminate(preservingCurrentLease: true)
        // AppKit termination is synchronous; retain this controller for bounded cleanup while the process remains alive.
        terminationCleanupTask = Task { @MainActor [self, lease] in
            _ = await self.removeOwnedPasteboardContent(for: lease)
            self.artifactOwner.discard(lease)
            self.terminationCleanupTask = nil
        }
    }

    func waitForTerminationCleanup() async {
        await terminationCleanupTask?.value
    }

    func cancelPendingConversion() {
        token &+= 1
        captureTask?.cancel()
        installTask?.cancel()
        worker.cancelAll()
    }

    private func install(
        url: URL,
        token: UInt64,
        sourceChangeCount: Int,
        completion: @escaping (Result) -> Void
    ) async {
        guard isCurrent(token: token, sourceChangeCount: sourceChangeCount) else {
            completeStale(url: url, completion: completion)
            return
        }
        guard let item = makePasteboardItem(url: url, completion: completion) else { return }
        guard let snapshot = await captureSnapshot(
            url: url,
            token: token,
            sourceChangeCount: sourceChangeCount,
            completion: completion
        ) else {
            return
        }
        guard isCurrent(token: token, sourceChangeCount: sourceChangeCount) else {
            completeStale(url: url, completion: completion)
            return
        }

        let replacement = await replaceSnapshot(
            snapshot: snapshot,
            item: item,
            token: token,
            sourceChangeCount: sourceChangeCount,
            url: url
        )
        guard !Task.isCancelled, self.token == token else {
            artifactOwner.removeGeneratedFile(at: url)
            discardLeaseIfGenerationChanged()
            completion(.stale)
            return
        }
        await finishReplacement(
            replacement.result,
            previousLease: replacement.previousLease,
            url: url,
            token: token,
            completion: completion
        )
    }

    private func isCurrent(token: UInt64, sourceChangeCount: Int) -> Bool {
        !Task.isCancelled
            && self.token == token
            && pasteboard.changeCount == sourceChangeCount
    }

    private func discardLeaseIfGenerationChanged() {
        guard let lease = artifactOwner.currentLease,
              pasteboard.changeCount != lease.changeCount else {
            return
        }
        artifactOwner.discard(lease)
    }

    private func isOwnedPasteboardContent(
        for lease: ClipboardWebPArtifactOwner.Lease,
        expectedChangeCount: Int? = nil,
        requireCurrentLease: Bool = true
    ) async -> Bool {
        let changeCount = expectedChangeCount ?? lease.changeCount
        guard !requireCurrentLease || artifactOwner.currentLease == lease,
              pasteboard.changeCount == changeCount,
              let url = await PasteboardSnapshot.exactFileURL(
                  from: pasteboard,
                   maximumItems: PasteboardSnapshotPolicy.maximumItems,
                   maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem,
                   expectedChangeCount: changeCount,
                   fileURLReader: self.fileURLReader
              ),
              !Task.isCancelled,
              pasteboard.changeCount == changeCount,
              !requireCurrentLease || artifactOwner.currentLease == lease else {
            return false
        }
        return url == lease.url.standardizedFileURL
    }

    private func removeOwnedPasteboardContent(
        for lease: ClipboardWebPArtifactOwner.Lease,
        requireCurrentLease: Bool = true
    ) async -> Bool {
        guard let transaction = pasteboard as? any PasteboardOwnershipTransaction,
              !Task.isCancelled,
              !requireCurrentLease || artifactOwner.currentLease == lease,
              pasteboard.changeCount == lease.changeCount else {
            return false
        }

        let configuration = PasteboardSnapshot.FileURLConfiguration(
            maximumItems: PasteboardSnapshotPolicy.maximumItems,
            maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem,
            maximumReadDuration: PasteboardSnapshot.maximumFileURLReadDuration,
            fileURLReader: fileURLReader
        )
        let result = await transaction.clearContentsIfCurrent(
            expectedChangeCount: lease.changeCount,
            matchingFileURL: lease.url,
            configuration: configuration,
            isStillOwned: { [weak self] in
                guard let self else { return false }
                return !Task.isCancelled
                    && (!requireCurrentLease || self.artifactOwner.currentLease == lease)
            }
        )
        guard !Task.isCancelled else { return false }
        guard case let .cleared(changeCount) = result else { return false }
        return pasteboard.changeCount == changeCount
    }

    private func expire(_ lease: ClipboardWebPArtifactOwner.Lease) async {
        guard artifactOwner.currentLease == lease else { return }
        guard await removeOwnedPasteboardContent(for: lease) else {
            artifactOwner.discard(lease)
            return
        }
        artifactOwner.discard(lease)
    }
}
extension ClipboardWebPController {
    private func captureAndEnqueue(
        pasteboard: any PasteboardAccess,
        requestToken: UInt64,
        skipAlreadyWebPFiles: Bool,
        completion: @escaping (Result) -> Void
    ) async {
        let capture = await ClipboardWebPPasteboardCapture.captureImage(
            from: pasteboard,
            skipAlreadyWebPFiles: skipAlreadyWebPFiles,
            fileURLReader: fileURLReader,
            payloadReader: payloadReader
        )
        guard !Task.isCancelled, requestToken == token else {
            completion(.stale)
            return
        }
        guard let captured = source(from: capture, completion: completion) else { return }
        guard isCurrent(token: requestToken, sourceChangeCount: captured.changeCount) else {
            completion(.stale)
            return
        }

        let artifactOwner = self.artifactOwner
        worker.enqueue(
            source: captured.source,
            outputDirectory: artifactOwner.outputDirectory,
            cleanup: { url in
                artifactOwner.removeGeneratedFile(at: url)
            },
            completion: { [weak self, artifactOwner] result in
                guard let self else {
                    if case let .success(url) = result {
                        artifactOwner.removeGeneratedFile(at: url)
                    }
                    return
                }
                self.handleWorkerResult(
                    result,
                    artifactOwner: artifactOwner,
                    requestToken: requestToken,
                    sourceChangeCount: captured.changeCount,
                    completion: completion
                )
            }
        )
    }

    private func source(
        from capture: ClipboardWebPCapture,
        completion: @escaping (Result) -> Void
    ) -> (source: ClipboardWebPSource, changeCount: Int)? {
        switch capture {
        case .alreadyWebP:
            completion(.alreadyWebP)
        case let .source(source, changeCount):
            return (source, changeCount)
        case .noImage:
            onMessage("No image to convert")
            completion(.noImage)
        case .unavailable:
            onMessage("Clipboard image unavailable")
            completion(.unavailable)
        case .failed:
            onMessage("Couldn’t convert image to WebP")
            completion(.failed)
        case .stale:
            discardLeaseIfGenerationChanged()
            completion(.stale)
        }
        return nil
    }

    private func handleWorkerResult(
        _ result: ClipboardWebPWorker.Result,
        artifactOwner: ClipboardWebPArtifactOwner,
        requestToken: UInt64,
        sourceChangeCount: Int,
        completion: @escaping (Result) -> Void
    ) {
        guard requestToken == token,
              pasteboard.changeCount == sourceChangeCount else {
            if case let .success(url) = result {
                artifactOwner.removeGeneratedFile(at: url)
            }
            discardLeaseIfGenerationChanged()
            completion(.stale)
            return
        }

        switch result {
        case let .success(url):
            installTask = Task { @MainActor [weak self, artifactOwner] in
                guard let self else {
                    artifactOwner.removeGeneratedFile(at: url)
                    return
                }
                await self.install(
                    url: url,
                    token: requestToken,
                    sourceChangeCount: sourceChangeCount,
                    completion: completion
                )
            }
        case let .failure(failure):
            if failure == .conversion(.invalidImage) {
                onMessage("No image to convert")
                completion(.noImage)
            } else {
                onMessage("Couldn’t convert image to WebP")
                completion(.failed)
            }
        case .cancelled:
            completion(.cancelled)
        }
    }
    private func makePasteboardItem(
        url: URL,
        completion: @escaping (Result) -> Void
    ) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        guard item.setString(url.absoluteString, forType: .fileURL) else {
            artifactOwner.removeGeneratedFile(at: url)
            onMessage("Couldn’t convert image to WebP")
            completion(.failed)
            return nil
        }
        return item
    }

    private func captureSnapshot(
        url: URL,
        token: UInt64,
        sourceChangeCount: Int,
        completion: @escaping (Result) -> Void
    ) async -> PasteboardSnapshot? {
        let captureResult = await PasteboardSnapshot.capture(
            from: pasteboard,
            expectedChangeCount: sourceChangeCount,
            limits: Self.snapshotLimits,
            fileURLReader: fileURLReader,
            payloadReader: payloadReader
        )
        guard isCurrent(token: token, sourceChangeCount: sourceChangeCount) else {
            completeStale(url: url, completion: completion)
            return nil
        }
        switch captureResult {
        case let .captured(snapshot):
            return snapshot
        case .stale:
            completeStale(url: url, completion: completion)
        case .failed:
            artifactOwner.removeGeneratedFile(at: url)
            onMessage("Couldn’t copy converted WebP")
            completion(.failed)
        }
        return nil
    }

    private func replaceSnapshot(
        snapshot: PasteboardSnapshot,
        item: NSPasteboardItem,
        token: UInt64,
        sourceChangeCount: Int,
        url: URL
    ) async -> (
        result: PasteboardSnapshot.ReplacementResult,
        previousLease: ClipboardWebPArtifactOwner.Lease?
    ) {
        if let lease = artifactOwner.currentLease,
           lease.changeCount != sourceChangeCount {
            artifactOwner.discard(lease)
        }
        let previousLease = artifactOwner.currentLease
        let result = await snapshot.replace(
            pasteboard: pasteboard,
            expectedChangeCount: sourceChangeCount,
            with: [item],
            maximumBytes: Self.snapshotLimits.maximumBytes,
            maximumTypesPerItem: Self.snapshotLimits.maximumTypesPerItem,
            fileURLReader: fileURLReader,
            payloadReader: payloadReader,
            verify: { [weak self] in
                guard let self,
                      !Task.isCancelled,
                      self.token == token else {
                    return false
                }
                let ownershipChangeCount = self.pasteboard.changeCount
                let owns = await PasteboardSnapshot.exactFileURL(
                    from: self.pasteboard,
                    maximumItems: PasteboardSnapshotPolicy.maximumItems,
                    maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem,
                    expectedChangeCount: ownershipChangeCount,
                    fileURLReader: self.fileURLReader
                ) == url.standardizedFileURL
                return !Task.isCancelled
                    && self.token == token
                    && self.pasteboard.changeCount == ownershipChangeCount
                    && owns
            }
        )
        return (result, previousLease)
    }

    private func completeStale(
        url: URL,
        completion: @escaping (Result) -> Void
    ) {
        artifactOwner.removeGeneratedFile(at: url)
        discardLeaseIfGenerationChanged()
        completion(.stale)
    }

    private func replacementIsCurrent(
        _ result: PasteboardSnapshot.ReplacementResult,
        token: UInt64
    ) -> Bool {
        guard !Task.isCancelled, self.token == token else { return false }
        switch result {
        case let .installed(changeCount):
            return pasteboard.changeCount == changeCount
        case let .failed(restoredChangeCount):
            return pasteboard.changeCount == restoredChangeCount
        case .restoreFailed, .stale:
            return true
        }
    }

    private func finishReplacement(
        _ result: PasteboardSnapshot.ReplacementResult,
        previousLease: ClipboardWebPArtifactOwner.Lease?,
        url: URL,
        token: UInt64,
        completion: @escaping (Result) -> Void
    ) async {
        guard replacementIsCurrent(result, token: token) else {
            artifactOwner.removeGeneratedFile(at: url)
            if case .failed = result {
                artifactOwner.discard(previousLease)
            } else {
                discardLeaseIfGenerationChanged()
            }
            completion(.stale)
            return
        }

        switch result {
        case let .installed(changeCount):
            artifactOwner.claim(url: url, changeCount: changeCount, token: token)
            onConverted(url, changeCount)
            completion(.converted(url))
        case let .failed(restoredChangeCount):
            await finishFailedReplacement(
                url: url,
                token: token,
                restoredChangeCount: restoredChangeCount,
                previousLease: previousLease,
                completion: completion
            )
        case .restoreFailed:
            artifactOwner.removeGeneratedFile(at: url)
            artifactOwner.discard(previousLease)
            onMessage("Couldn’t restore clipboard")
            completion(.failed)
        case .stale:
            artifactOwner.removeGeneratedFile(at: url)
            artifactOwner.discard(previousLease)
            completion(.stale)
        }
    }

    private func finishFailedReplacement(
        url: URL,
        token: UInt64,
        restoredChangeCount: Int,
        previousLease: ClipboardWebPArtifactOwner.Lease?,
        completion: @escaping (Result) -> Void
    ) async {
        artifactOwner.removeGeneratedFile(at: url)
        await artifactOwner.restore(previousLease, changeCount: restoredChangeCount) {
            guard let previousLease else { return false }
            return await self.isOwnedPasteboardContent(
                for: previousLease,
                expectedChangeCount: restoredChangeCount
            )
        }
        guard !Task.isCancelled,
              self.token == token,
              pasteboard.changeCount == restoredChangeCount else {
            completion(.stale)
            return
        }
        onMessage("Couldn’t copy converted WebP")
        completion(.failed)
    }
}
