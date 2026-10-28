import Foundation

@MainActor
final class MacArtifactCleanupProcessor {
    typealias FingerprintReader = @Sendable (MacArtifactMatch) async throws -> MacArtifactFingerprint

    private struct PendingCandidate {
        let rootID: UUID
        var match: MacArtifactMatch
        var lastActivity: Date
        var automaticPreviewCompleted = false
        var manualRetryOnly = false
    }

    private struct FingerprintOutcome: Sendable {
        let fingerprint: MacArtifactFingerprint?
        let failure: String?
    }

    private struct RunSummary {
        var matched = 0
        var removed = 0
        var skipped = 0
        var details: [String] = []
    }

    static let quietPeriod: TimeInterval = 30

    var onChange: (() -> Void)?
    var onRootChanged: (() -> Void)?

    private let store: MacArtifactCleanupStore
    private let scanner = MacArtifactCleanupScanEngine()
    private let notifier: MacArtifactCleanupNotifier
    private let quietPeriod: TimeInterval
    private let fingerprintReader: FingerprintReader
    private var timer: Timer?
    private var running = false
    private var generation: UInt64 = 0
    private var activeRoots: [UUID: MacArtifactCleanupRoot] = [:]
    private var candidates: [String: PendingCandidate] = [:]
    private var processingToken: UUID?
    private var candidateFingerprintTask: Task<FingerprintOutcome, Never>?
    private var timerTask: Task<Void, Never>?
    private var timerTaskToken: UUID?


    init(
        store: MacArtifactCleanupStore,
        notifier: MacArtifactCleanupNotifier,
        quietPeriod: TimeInterval = 30,
        fingerprintReader: @escaping FingerprintReader = { match in
            try MacArtifactScanner.fingerprint(for: match)
        }
    ) {
        self.store = store
        self.notifier = notifier
        self.quietPeriod = quietPeriod
        self.fingerprintReader = fingerprintReader
        scanner.onScanResult = { [weak self] root, result in self?.didScan(root, result: result) }
        scanner.onScanFailure = { [weak self] root, message in self?.didFailScan(root, message: message) }
        scanner.onMatch = { [weak self] root, match in self?.didFind(match, under: root) }
        scanner.onInspectionFailure = { [weak self] root, url, message in
            self?.didFailInspection(root, url: url, message: message)
        }
        scanner.onRootChanged = { [weak self] in self?.onRootChanged?() }
    }

    func start(roots: [MacArtifactCleanupRoot]) {
        guard !running else { return }
        running = true
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleTimerProcessing() }
        }
        activeRoots = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        scanner.start(roots: roots)
        onChange?()
    }

    func stop() {
        guard running else { return }
        running = false
        generation &+= 1
        timer?.invalidate()
        timer = nil
        timerTask?.cancel()
        scanner.stop()
        cancelCandidateProcessing()
        candidates.removeAll()
        notifier.stop()
        onChange?()
    }
    func waitForBackgroundScans() async {
        if let timerTask { await timerTask.value }
        await scanner.waitForBackgroundScans()
    }
    private func scheduleTimerProcessing() {
        guard running, timerTask == nil else { return }
        let token = UUID()
        timerTaskToken = token
        timerTask = Task { @MainActor [weak self] in
            await self?.processMatureCandidates()
            guard let self, self.timerTaskToken == token else { return }
            self.timerTask = nil
            self.timerTaskToken = nil
        }
    }

    func updateRoots(_ roots: [MacArtifactCleanupRoot]) {
        guard running else { return }
        generation &+= 1
        cancelCandidateProcessing()
        candidates.removeAll()
        activeRoots = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        scanner.updateRoots(roots)
        onChange?()
    }

    func receive(_ events: [MacArtifactFileEvent]) {
        guard running else { return }
        scanner.receive(events.filter { event in
            let activityObserved = markActivity(at: event.path)
            return !activityObserved
                || MacArtifactScanner.mayMatch(URL(fileURLWithPath: event.path).lastPathComponent)
        })
    }

    func preview(rootID: UUID) async throws -> MacArtifactScanResult {
        guard running, let root = activeRoots[rootID] else { throw CancellationError() }
        let expectedGeneration = generation
        let result = try await scanner.preview(rootID: rootID)
        guard running,
              !Task.isCancelled,
              generation == expectedGeneration,
              activeRoots[rootID]?.path == root.path,
              root.isOnOriginalVolume,
              store.configuration.roots.contains(where: { $0.id == rootID }) else {
            throw CancellationError()
        }
        return result
    }

    @discardableResult
    func applyManually(
        _ matches: [MacArtifactMatch],
        rootID: UUID,
        mode: MacArtifactRemovalMode
    ) -> MacArtifactCleanupHistoryEntry? {
        guard running,
              processingToken == nil,
              let root = activeRoots[rootID],
              root.isOnOriginalVolume,
              store.configuration.roots.contains(where: {
                  $0.id == rootID && $0.path == root.path && $0.volumeIdentifier == root.volumeIdentifier
              }) else {
            return nil
        }
        var summary = RunSummary(matched: matches.count)
        for match in matches {
            guard match.rootURL.standardizedFileURL == root.url.standardizedFileURL else {
                summary.skipped += 1
                summary.details.append("Preview belongs to a different selected root: \(match.url.path)")
                continue
            }
            guard let candidate = candidates[match.id],
                  candidate.rootID == rootID,
                  candidate.match.url.standardizedFileURL == match.url.standardizedFileURL,
                  candidate.match.rootURL.standardizedFileURL == match.rootURL.standardizedFileURL,
                  candidate.match.rootDevice == match.rootDevice,
                  candidate.match.kind == match.kind else {
                summary.skipped += 1
                summary.details.append("Manual cleanup skipped because monitoring has not observed this item.")
                continue
            }
            var currentCandidate = candidate
            currentCandidate.match = match
            if candidate.match.fingerprint != match.fingerprint {
                currentCandidate.lastActivity = Date()
            }
            candidates[match.id] = currentCandidate
            guard Date().timeIntervalSince(currentCandidate.lastActivity) >= quietPeriod else {
                summary.skipped += 1
                summary.details.append(
                    "Manual cleanup skipped: the item must remain unchanged for at least \(Int(quietPeriod)) seconds."
                )
                continue
            }
            let result = MacArtifactCleaner.apply(match, mode: mode)
            if case .failed = result {
                var retryCandidate = currentCandidate
                retryCandidate.manualRetryOnly = true
                candidates[match.id] = retryCandidate
            } else {
                candidates.removeValue(forKey: match.id)
            }
            record(result, match: match, summary: &summary)
        }
        let entry = makeHistoryEntry(root: root, mode: mode, summary: summary)
        store.record(entry)
        notify(entry)
        onChange?()
        return entry
    }

    private func cancelCandidateProcessing() {
        candidateFingerprintTask?.cancel()
        candidateFingerprintTask = nil
        processingToken = nil
    }

    private func didScan(_ root: MacArtifactCleanupRoot, result: MacArtifactScanResult) {
        guard running, activeRoots[root.id]?.path == root.path, root.isOnOriginalVolume else { return }
        register(result.matches, foundUnder: root)
        guard !result.issues.isEmpty else { return }
        let entry = MacArtifactCleanupHistoryEntry(
            rootPath: root.path,
            mode: store.configuration.mode(for: root),
            matchedCount: 0,
            removedCount: 0,
            skippedCount: result.issues.count,
            details: result.issues.prefix(20).map { "\($0.path): \($0.reason)" }
        )
        store.record(entry)
        notify(entry)
    }

    private func didFailScan(_ root: MacArtifactCleanupRoot, message: String) {
        guard running, activeRoots[root.id]?.path == root.path, root.isOnOriginalVolume else { return }
        recordIssue(root, details: [message])
    }

    private func didFind(_ match: MacArtifactMatch, under root: MacArtifactCleanupRoot) {
        guard running,
              activeRoots[root.id]?.path == root.path,
              match.rootURL.standardizedFileURL == root.url.standardizedFileURL,
              root.isOnOriginalVolume else {
            return
        }
        register([match], foundUnder: root)
    }

    private func didFailInspection(_ root: MacArtifactCleanupRoot, url: URL, message: String) {
        guard running, activeRoots[root.id]?.path == root.path, root.isOnOriginalVolume else { return }
        recordIssue(root, details: ["\(url.path): \(message)"])
    }

    private func recordIssue(_ root: MacArtifactCleanupRoot, details: [String]) {
        let entry = MacArtifactCleanupHistoryEntry(
            rootPath: root.path,
            mode: store.configuration.mode(for: root),
            matchedCount: 0,
            removedCount: 0,
            skippedCount: details.count,
            details: Array(details.prefix(20))
        )
        store.record(entry)
        onChange?()
        notify(entry)
    }

    private func register(_ matches: [MacArtifactMatch], foundUnder scannedRoot: MacArtifactCleanupRoot) {
        let now = Date()
        for match in matches {
            let owner = MacArtifactCleanupRoot.containing(path: match.url.path, in: activeRoots.values) ?? scannedRoot
            guard match.rootURL.standardizedFileURL == owner.url.standardizedFileURL else { continue }
            if let existing = candidates[match.id], existing.rootID == owner.id {
                guard existing.match.fingerprint != match.fingerprint else { continue }
                candidates[match.id] = PendingCandidate(
                    rootID: owner.id,
                    match: match,
                    lastActivity: now,
                    automaticPreviewCompleted: false,
                    manualRetryOnly: existing.manualRetryOnly
                )
            } else {
                candidates[match.id] = PendingCandidate(rootID: owner.id, match: match, lastActivity: now)
            }
        }
        onChange?()
    }

    private func markActivity(at path: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let now = Date()
        var affected = false
        for candidateID in Array(candidates.keys) {
            guard var candidate = candidates[candidateID] else { continue }
            let candidatePath = candidate.match.url.standardizedFileURL.path
            let isMetadataDirectory = candidate.match.kind == .metadataDirectory
            let sidecarURL = URL(fileURLWithPath: candidatePath)
            let companionPath = candidate.match.kind == .appleDoubleSidecar
                ? sidecarURL.deletingLastPathComponent()
                    .appendingPathComponent(String(sidecarURL.lastPathComponent.dropFirst(2))).path
                : nil
            if normalizedPath == candidatePath
                || (isMetadataDirectory && normalizedPath.hasPrefix(candidatePath + "/"))
                || normalizedPath == companionPath {
                candidate.lastActivity = now
                candidate.automaticPreviewCompleted = false
                candidates[candidateID] = candidate
                affected = true
            }
        }
        return affected
    }

    func processMatureCandidates() async {
        guard running, processingToken == nil else { return }
        let now = Date()
        let due = candidates.values
            .filter {
                now.timeIntervalSince($0.lastActivity) >= quietPeriod
                    && !$0.automaticPreviewCompleted
                    && !$0.manualRetryOnly
            }
            .sorted { MacArtifactMatch.cleanupPrecedes($0.match, $1.match) }
        guard !due.isEmpty else { return }

        let token = UUID()
        processingToken = token
        await process(due, token: token, generation: generation)
    }

    private func process(
        _ due: [PendingCandidate],
        token: UUID,
        generation expectedGeneration: UInt64
    ) async {
        var summaries: [UUID: RunSummary] = [:]
        var rootsForSummary: [UUID: MacArtifactCleanupRoot] = [:]
        for original in due {
            let fingerprintReader = self.fingerprintReader
            let worker = Task.detached(priority: .utility) {
                do {
                    return FingerprintOutcome(
                        fingerprint: try await fingerprintReader(original.match),
                        failure: nil
                    )
                } catch {
                    return FingerprintOutcome(fingerprint: nil, failure: error.localizedDescription)
                }
            }
            candidateFingerprintTask = worker
            let validation = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard running,
                  !Task.isCancelled,
                  generation == expectedGeneration,
                  processingToken == token,
                  let current = candidates[original.match.id],
                  current.rootID == original.rootID,
                  current.match == original.match,
                  Date().timeIntervalSince(current.lastActivity) >= quietPeriod,
                  let root = activeRoots[original.rootID],
                  root.url.standardizedFileURL == original.match.rootURL.standardizedFileURL,
                  store.configuration.roots.contains(where: { $0.id == original.rootID }),
                  root.isOnOriginalVolume else {
                finishProcessing(token: token)
                return
            }
            candidateFingerprintTask = nil

            var summary = summaries[original.rootID] ?? RunSummary()
            summary.matched += 1
            rootsForSummary[original.rootID] = root
            if let fingerprint = validation.fingerprint,
               fingerprint == original.match.fingerprint {
                let mode = store.configuration.mode(for: root)
                let result = MacArtifactCleaner.apply(original.match, mode: mode)
                record(result, match: original.match, summary: &summary)
                if result == .previewed {
                    candidates[original.match.id]?.automaticPreviewCompleted = true
                } else if result != .changedSinceScan {
                    candidates.removeValue(forKey: original.match.id)
                } else {
                    candidates[original.match.id]?.lastActivity = Date()
                }
            } else if let fingerprint = validation.fingerprint {
                candidates[original.match.id] = PendingCandidate(
                    rootID: original.rootID,
                    match: MacArtifactMatch(
                        url: original.match.url,
                        rootURL: original.match.rootURL,
                        rootDevice: original.match.rootDevice,
                        kind: original.match.kind,
                        fingerprint: fingerprint
                    ),
                    lastActivity: Date()
                )
                summary.skipped += 1
                summary.details.append("Changed while waiting: \(original.match.url.path)")
            } else {
                candidates.removeValue(forKey: original.match.id)
                summary.skipped += 1
                summary.details.append("\(original.match.url.path): \(validation.failure ?? "Could not verify the item.")")
            }
            summaries[original.rootID] = summary
        }

        var notificationLines: [String] = []
        for rootID in summaries.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let root = rootsForSummary[rootID], let summary = summaries[rootID] else { continue }
            let entry = makeHistoryEntry(
                root: root,
                mode: store.configuration.mode(for: root),
                summary: summary
            )
            store.record(entry)
            notificationLines.append(
                "\(summary.removed) removed from \(root.url.lastPathComponent); \(summary.skipped) skipped"
            )
        }
        finishProcessing(token: token)
        if !notificationLines.isEmpty {
            notify(title: "Mac cleanup complete", body: notificationLines.joined(separator: ". "))
        }
        onChange?()
    }

    private func finishProcessing(token: UUID) {
        guard processingToken == token else { return }
        processingToken = nil
        candidateFingerprintTask = nil
    }

    private func record(
        _ result: MacArtifactRemovalResult,
        match: MacArtifactMatch,
        summary: inout RunSummary
    ) {
        switch result {
        case .previewed:
            summary.details.append("Preview only: \(match.url.path)")
        case .movedToTrash(_), .deleted:
            summary.removed += 1
        case .changedSinceScan:
            summary.skipped += 1
            summary.details.append("Changed before removal: \(match.url.path)")
        case .failed(let reason):
            summary.skipped += 1
            summary.details.append("\(match.url.path): \(reason)")
        }
    }

    private func makeHistoryEntry(
        root: MacArtifactCleanupRoot,
        mode: MacArtifactRemovalMode,
        summary: RunSummary
    ) -> MacArtifactCleanupHistoryEntry {
        MacArtifactCleanupHistoryEntry(
            rootPath: root.path,
            mode: mode,
            matchedCount: summary.matched,
            removedCount: summary.removed,
            skippedCount: summary.skipped,
            details: Array(summary.details.prefix(20))
        )
    }

    private func notify(_ entry: MacArtifactCleanupHistoryEntry) {
        let folderName = URL(fileURLWithPath: entry.rootPath).lastPathComponent
        sendNotification(
            title: "Mac cleanup complete",
            body: "\(entry.removedCount) removed; \(entry.skippedCount) skipped from \(folderName)."
        )
    }

    private func notify(title: String, body: String) {
        sendNotification(title: title, body: body)
    }

    private func sendNotification(title: String, body: String) {
        guard running else { return }
        notifier.send(
            title: title,
            body: body,
            isCurrent: { [weak self] in self?.running == true }
        )
    }

}
