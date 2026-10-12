import AppKit

@MainActor
final class ClipboardImagePasteboardInstaller {
    enum Result {
        case installed(URL)
        case failed
        case stale
    }

    private let pasteboard: any PasteboardAccess
    private let artifactOwner: ClipboardImageConversionArtifactOwner
    private let onConverted: (URL, Int) -> Void
    private let onMessage: (String) -> Void
    private let fileURLReader: any PasteboardFileURLReading
    private let payloadReader: any PasteboardPayloadReading
    private var token: UInt64 = 0
    private var installTask: Task<Void, Never>?
    private var terminationCleanupTask: Task<Void, Never>?
    private var terminated = false

    var isTerminated: Bool { terminated }
    var outputDirectory: URL { artifactOwner.outputDirectory }

    init(
        pasteboard: any PasteboardAccess,
        expirationInterval: TimeInterval,
        outputDirectory: URL,
        fileURLReader: any PasteboardFileURLReading,
        payloadReader: any PasteboardPayloadReading,
        onConverted: @escaping (URL, Int) -> Void,
        onMessage: @escaping (String) -> Void
    ) {
        self.pasteboard = pasteboard
        self.fileURLReader = fileURLReader
        self.payloadReader = payloadReader
        self.onConverted = onConverted
        self.onMessage = onMessage
        artifactOwner = ClipboardImageConversionArtifactOwner(
            expirationInterval: expirationInterval,
            outputDirectory: outputDirectory,
            legacyOutputDirectories: ClipboardImageConversionPolicy.legacyOutputDirectories,
            pasteboard: pasteboard,
            fileURLReader: fileURLReader,
            onMessage: onMessage,
            currentGeneration: { pasteboard.changeCount }
        )
        artifactOwner.onExpired = { [weak self] lease in
            await self?.expire(lease)
        }
    }

    func beginRequest() -> UInt64 {
        token &+= 1
        installTask?.cancel()
        return token
    }

    func cancelPendingConversion() {
        token &+= 1
        installTask?.cancel()
    }

    func terminate() {
        guard !terminated else { return }
        terminated = true
        token &+= 1
        installTask?.cancel()
        installTask = nil
        let lease = artifactOwner.currentLease
        guard let lease else {
            artifactOwner.terminate()
            return
        }
        artifactOwner.terminate(preservingCurrentLease: true)
        terminationCleanupTask = Task { @MainActor [self, lease] in
            _ = await removeOwnedPasteboardContent(for: lease)
            artifactOwner.discard(lease)
            terminationCleanupTask = nil
        }
    }

    func waitForTerminationCleanup() async {
        await terminationCleanupTask?.value
    }

    func isRequestCurrent(token: UInt64) -> Bool {
        !terminated && self.token == token
    }

    func removeGeneratedFile(at url: URL) {
        artifactOwner.removeGeneratedFile(at: url)
    }

    func enqueueInstallation(
        url: URL,
        snapshot: PasteboardSnapshot,
        token: UInt64,
        sourceChangeCount: Int,
        completion: @escaping (Result) -> Void
    ) {
        let artifactOwner = self.artifactOwner
        installTask = Task { @MainActor [weak self, artifactOwner] in
            guard let self else {
                artifactOwner.removeGeneratedFile(at: url)
                return
            }
            await self.install(
                url: url,
                snapshot: snapshot,
                token: token,
                sourceChangeCount: sourceChangeCount,
                completion: completion
            )
        }
    }
    func isCurrent(token: UInt64, sourceChangeCount: Int) -> Bool {
        !Task.isCancelled
            && self.token == token
            && pasteboard.changeCount == sourceChangeCount
    }

    func discardLeaseIfGenerationChanged() {
        guard let lease = artifactOwner.currentLease,
              pasteboard.changeCount != lease.changeCount else {
            return
        }
        artifactOwner.discard(lease)
    }
}

private extension ClipboardImagePasteboardInstaller {
    func install(
        url: URL,
        snapshot: PasteboardSnapshot,
        token: UInt64,
        sourceChangeCount: Int,
        completion: @escaping (Result) -> Void
    ) async {
        guard isCurrent(token: token, sourceChangeCount: sourceChangeCount) else {
            completeStale(url: url, completion: completion)
            return
        }
        guard let item = makePasteboardItem(url: url, completion: completion) else { return }

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

    func isOwnedPasteboardContent(
        for lease: ClipboardImageConversionArtifactOwner.Lease,
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
        for lease: ClipboardImageConversionArtifactOwner.Lease,
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

    private func expire(_ lease: ClipboardImageConversionArtifactOwner.Lease) async {
        guard artifactOwner.currentLease == lease else { return }
        guard await removeOwnedPasteboardContent(for: lease) else {
            artifactOwner.discard(lease)
            return
        }
        artifactOwner.discard(lease)
    }
    func makePasteboardItem(
        url: URL,
        completion: @escaping (Result) -> Void
    ) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        guard item.setString(url.absoluteString, forType: .fileURL) else {
            artifactOwner.removeGeneratedFile(at: url)
            onMessage("Couldn’t convert clipboard image")
            completion(.failed)
            return nil
        }
        return item
    }

    func replaceSnapshot(
        snapshot: PasteboardSnapshot,
        item: NSPasteboardItem,
        token: UInt64,
        sourceChangeCount: Int,
        url: URL
    ) async -> (
        result: PasteboardSnapshot.ReplacementResult,
        previousLease: ClipboardImageConversionArtifactOwner.Lease?
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
            maximumBytes: PasteboardSnapshotPolicy.maximumBytes,
            maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem,
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

    func completeStale(
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

    func finishReplacement(
        _ result: PasteboardSnapshot.ReplacementResult,
        previousLease: ClipboardImageConversionArtifactOwner.Lease?,
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
            completion(.installed(url))
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
        previousLease: ClipboardImageConversionArtifactOwner.Lease?,
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
        onMessage("Couldn’t copy converted clipboard image")
        completion(.failed)
    }
}
