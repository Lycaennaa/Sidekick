import Foundation

@MainActor
final class ClipboardImageConversionArtifactOwner {
    struct Lease: Equatable, Sendable {
        let url: URL
        let changeCount: Int
        let token: UInt64
        let expiresAt: Date
    }

    typealias ExpirationHandler = @MainActor (Lease) async -> Void
    typealias CleanupCompletion = @MainActor (URL) -> Void

    let outputDirectory: URL
    var onExpired: ExpirationHandler
    private let ownedOutputDirectories: [URL]

    private let expirationInterval: TimeInterval
    private let onMessage: (String) -> Void
    private let onCleanupComplete: CleanupCompletion
    private let removeItem: (URL) throws -> Void
    private let fileURLReader: any PasteboardFileURLReading
    private let ownershipTransaction: (any PasteboardOwnershipTransaction)?
    private let currentGeneration: @MainActor () -> Int?
    private var expirationTimer: Timer?
    private(set) var currentLease: Lease?
    private var pendingDeletionURLs: Set<URL> = []
    private var deletionTaskURLs: Set<URL> = []
    private var startupCleanupTask: Task<Void, Never>?
    private var cleanupTimer: Timer?
    private var cleanupRetryCount = 0
    private(set) var isTerminated = false

    init(
        expirationInterval: TimeInterval,
        outputDirectory: URL,
        legacyOutputDirectories: [URL] = [],
        pasteboard: (any PasteboardAccess)? = nil,
        fileURLReader: any PasteboardFileURLReading = SystemPasteboardFileURLReader(),
        onExpired: @escaping ExpirationHandler = { _ in },
        onMessage: @escaping (String) -> Void = { _ in },
        removeItem: @escaping (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        },
        onCleanupComplete: @escaping CleanupCompletion = { _ in },
        currentGeneration: @escaping @MainActor () -> Int? = { nil }
    ) {
        self.expirationInterval = expirationInterval
        self.outputDirectory = outputDirectory
        ownedOutputDirectories = [outputDirectory] + legacyOutputDirectories.filter {
            $0.standardizedFileURL != outputDirectory.standardizedFileURL
        }
        self.fileURLReader = fileURLReader
        ownershipTransaction = pasteboard as? any PasteboardOwnershipTransaction
        self.onExpired = onExpired
        self.onMessage = onMessage
        self.removeItem = removeItem
        self.onCleanupComplete = onCleanupComplete
        self.currentGeneration = currentGeneration
        resetOutputDirectory()
    }

    private func resetOutputDirectory() {
        try? FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let candidates = ownedOutputDirectories.flatMap { directory -> [URL] in
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) else {
                return []
            }
            return urls.filter {
                ClipboardImageConversionFileService.isOwnedOutputURL($0, in: directory)
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
            }
        }
        startupCleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for url in candidates {
                guard !Task.isCancelled, !self.isTerminated else { return }
                let generation = self.currentGeneration()
                let result = await self.deleteFileIfUnreferenced(
                    url,
                    expectedChangeCount: generation,
                    isStillOwned: { [weak self] in
                        guard let self else { return false }
                        return !self.isTerminated
                            && self.currentLease?.url.standardizedFileURL
                                != url.standardizedFileURL
                    }
                )
                guard !Task.isCancelled, !self.isTerminated else { return }
                switch result {
                case .deleted:
                    self.markDeletionComplete(url)
                case .retained, .stale, .unavailable:
                    self.retainForCleanup(url)
                }
            }
            self.startupCleanupTask = nil
        }
    }

    func waitForStartupCleanup() async {
        await startupCleanupTask?.value
    }

    @discardableResult
    func claim(url: URL, changeCount: Int, token: UInt64) -> Lease {
        expirationTimer?.invalidate()
        expirationTimer = nil
        let previousLease = currentLease
        let lease = Lease(
            url: url,
            changeCount: changeCount,
            token: token,
            expiresAt: Date().addingTimeInterval(expirationInterval)
        )
        currentLease = lease
        scheduleExpiration(for: lease)
        if let previousLease {
            discard(previousLease)
        }
        return lease
    }

    func restore(
        _ lease: Lease?,
        changeCount: Int,
        isOwned: @escaping @MainActor () async -> Bool
    ) async {
        guard !Task.isCancelled, let lease else { return }
        guard currentLease == lease else {
            discard(lease)
            return
        }
        let wasOwned = await isOwned()
        guard !Task.isCancelled, !isTerminated, currentLease == lease else { return }
        guard currentGeneration().map({ $0 == changeCount }) ?? true else {
            discard(lease)
            return
        }
        guard wasOwned else {
            discard(lease)
            return
        }

        expirationTimer?.invalidate()
        expirationTimer = nil
        let restoredLease = Lease(
            url: lease.url,
            changeCount: changeCount,
            token: lease.token,
            expiresAt: lease.expiresAt
        )
        currentLease = restoredLease
        scheduleExpiration(for: restoredLease)
    }

    func discard(_ lease: Lease?) {
        guard let lease else { return }
        if currentLease == lease {
            expirationTimer?.invalidate()
            expirationTimer = nil
            currentLease = nil
        }
        removeGeneratedFile(at: lease.url)
    }

    func removeGeneratedFile(at url: URL) {
        guard ownedOutputDirectories.contains(where: {
            ClipboardImageConversionFileService.isOwnedOutputURL(url, in: $0)
        }) else {
            return
        }
        guard currentLease?.url.standardizedFileURL != url.standardizedFileURL else {
            pendingDeletionURLs.remove(url)
            return
        }
        guard deletionTaskURLs.insert(url).inserted else { return }
        let generation = currentGeneration()
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.deletionTaskURLs.remove(url)
                self.onCleanupComplete(url)
            }
            let result = await self.deleteFileIfUnreferenced(
                url,
                expectedChangeCount: generation,
                isStillOwned: { [weak self] in
                    guard let self else { return false }
                    return self.currentLease?.url.standardizedFileURL
                        != url.standardizedFileURL
                }
            )
            guard self.currentLease?.url.standardizedFileURL != url.standardizedFileURL else {
                self.pendingDeletionURLs.remove(url)
                return
            }
            guard !Task.isCancelled else {
                self.retainForCleanup(url)
                return
            }
            switch result {
            case .deleted:
                self.markDeletionComplete(url)
            case .retained, .stale, .unavailable:
                self.retainForCleanup(url)
            }
        }
    }

    func terminate(preservingCurrentLease: Bool = false) {
        isTerminated = true
        startupCleanupTask?.cancel()
        startupCleanupTask = nil
        expirationTimer?.invalidate()
        expirationTimer = nil
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        if !preservingCurrentLease, let lease = currentLease {
            currentLease = nil
            removeGeneratedFile(at: lease.url)
        }
        if !preservingCurrentLease {
            retryPendingDeletions()
        }
    }

    private func scheduleExpiration(for lease: Lease) {
        guard !isTerminated else { return }
        let timer = Timer(
            timeInterval: max(0, lease.expiresAt.timeIntervalSinceNow),
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.expire(lease)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        expirationTimer = timer
    }

    private func expire(_ lease: Lease) {
        guard currentLease == lease else { return }
        expirationTimer = nil
        Task { @MainActor [weak self] in
            guard let self, self.currentLease == lease else { return }
            await self.onExpired(lease)
            guard self.currentLease == lease, !Task.isCancelled else { return }
            self.currentLease = nil
            self.removeGeneratedFile(at: lease.url)
        }
    }

    private func deleteFileIfUnreferenced(
        _ url: URL,
        expectedChangeCount: Int?,
        isStillOwned: @escaping @MainActor () -> Bool
    ) async -> PasteboardConditionalArtifactDeletionResult {
        guard let ownershipTransaction,
              let expectedChangeCount else {
            return .unavailable
        }
        let configuration = PasteboardSnapshot.FileURLConfiguration(
            maximumItems: PasteboardSnapshotPolicy.maximumItems,
            maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem,
            maximumReadDuration: PasteboardSnapshot.maximumFileURLReadDuration,
            fileURLReader: fileURLReader
        )
        return await ownershipTransaction.deleteFileIfUnreferenced(
            url,
            expectedChangeCount: expectedChangeCount,
            configuration: configuration,
            isStillOwned: isStillOwned,
            removeItem: { [removeItem] url in
                try removeItem(url)
            }
        )
    }

    private func markDeletionComplete(_ url: URL) {
        pendingDeletionURLs.remove(url)
        guard pendingDeletionURLs.isEmpty else { return }
        cleanupTimer?.invalidate()
        cleanupTimer = nil
        cleanupRetryCount = 0
    }

    private func retainForCleanup(_ url: URL) {
        pendingDeletionURLs.insert(url)
        scheduleCleanupRetry()
    }

    private func scheduleCleanupRetry() {
        guard !isTerminated, cleanupTimer == nil, cleanupRetryCount < 5 else {
            if cleanupRetryCount >= 5 {
                onMessage("Couldn’t remove temporary converted image")
            }
            return
        }
        cleanupRetryCount += 1
        let timer = Timer(timeInterval: 1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cleanupTimer = nil
                self.retryPendingDeletions()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cleanupTimer = timer
    }

    private func retryPendingDeletions() {
        let urls = pendingDeletionURLs
        for url in urls {
            removeGeneratedFile(at: url)
        }
        if !pendingDeletionURLs.isEmpty {
            scheduleCleanupRetry()
        }
    }
}
