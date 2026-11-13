import Foundation

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

    mutating func merge(_ other: RunSummary) {
        matched += other.matched
        removed += other.removed
        skipped += other.skipped
        details.append(contentsOf: other.details)
    }

    mutating func record(_ result: MacArtifactRemovalResult, match: MacArtifactMatch) {
        switch result {
        case .previewed:
            details.append("Preview only: \(match.url.path)")
        case .movedToTrash, .deleted:
            removed += 1
        case .changedSinceScan:
            skipped += 1
            details.append("Changed before removal: \(match.url.path)")
        case .failed(let reason):
            skipped += 1
            details.append("\(match.url.path): \(reason)")
        }
    }

    func historyEntry(
        root: MacArtifactCleanupRoot,
        mode: MacArtifactRemovalMode
    ) -> MacArtifactCleanupHistoryEntry {
        MacArtifactCleanupHistoryEntry(
            rootPath: root.path,
            mode: mode,
            matchedCount: matched,
            removedCount: removed,
            skippedCount: skipped,
            details: Array(details.prefix(20))
        )
    }
}

@MainActor
private final class MacArtifactCleanupCandidateState {
    private let store: MacArtifactCleanupStore
    private let quietPeriod: TimeInterval
    private var running = false
    private var generation: UInt64 = 0
    private var activeRoots: [UUID: MacArtifactCleanupRoot] = [:]
    private var candidates: [String: PendingCandidate] = [:]

    var isRunning: Bool { running }

    init(store: MacArtifactCleanupStore, quietPeriod: TimeInterval) {
        self.store = store
        self.quietPeriod = quietPeriod
    }

    func start(roots: [MacArtifactCleanupRoot]) {
        guard !running else { return }
        running = true
        activeRoots = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
    }

    func stop() {
        guard running else { return }
        running = false
        generation &+= 1
        candidates.removeAll()
    }

    func updateRoots(_ roots: [MacArtifactCleanupRoot]) {
        guard running else { return }
        generation &+= 1
        candidates.removeAll()
        activeRoots = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
    }

    func isCurrent(_ root: MacArtifactCleanupRoot) -> Bool {
        running && activeRoots[root.id]?.path == root.path && root.isOnOriginalVolume
    }

    func previewContext(rootID: UUID) throws -> MacArtifactCleanupCandidateLifecycle.PreviewContext {
        guard running, let root = activeRoots[rootID] else { throw CancellationError() }
        return .init(root: root, generation: generation)
    }

    func completePreview(
        _ result: MacArtifactScanResult,
        context: MacArtifactCleanupCandidateLifecycle.PreviewContext,
        registerCandidates: Bool
    ) throws -> MacArtifactScanResult {
        let root = context.root
        guard running,
              !Task.isCancelled,
              generation == context.generation,
              activeRoots[root.id]?.path == root.path,
              root.isOnOriginalVolume,
              store.configuration.roots.contains(where: { $0.id == root.id }) else {
            throw CancellationError()
        }
        guard registerCandidates else { return result }
        let matches = register(
            result.matches,
            foundUnder: root,
            returnMatchesOwnedByScannedRoot: true
        ) ?? []
        return MacArtifactScanResult(matches: matches, issues: result.issues)
    }

    @discardableResult
    func applyManually(
        _ matches: [MacArtifactMatch],
        rootID: UUID,
        mode: MacArtifactRemovalMode
    ) -> MacArtifactCleanupHistoryEntry? {
        guard running,
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
            summary.record(result, match: match)
        }
        let entry = summary.historyEntry(root: root, mode: mode)
        store.record(entry)
        return entry
    }

    func register(
        _ matches: [MacArtifactMatch],
        foundUnder scannedRoot: MacArtifactCleanupRoot,
        returnMatchesOwnedByScannedRoot: Bool = false
    ) -> [MacArtifactMatch]? {
        let now = Date()
        var matchesOwnedByScannedRoot: [MacArtifactMatch]? = returnMatchesOwnedByScannedRoot ? [] : nil
        for match in matches {
            let owner = MacArtifactCleanupRoot.containing(path: match.url.path, in: activeRoots.values) ?? scannedRoot
            guard match.rootURL.standardizedFileURL == owner.url.standardizedFileURL else { continue }
            if owner.id == scannedRoot.id {
                matchesOwnedByScannedRoot?.append(match)
            }
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
        return matchesOwnedByScannedRoot
    }

    func markActivity(at path: String) -> Bool {
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

    func nextRun() -> (candidates: [PendingCandidate], generation: UInt64)? {
        guard running else { return nil }
        let now = Date()
        let due = candidates.values
            .filter {
                now.timeIntervalSince($0.lastActivity) >= quietPeriod
                    && !$0.automaticPreviewCompleted
                    && !$0.manualRetryOnly
            }
            .sorted { MacArtifactMatch.cleanupPrecedes($0.match, $1.match) }
        guard !due.isEmpty else { return nil }
        return (due, generation)
    }

    func validatedRoot(
        for candidate: PendingCandidate,
        expectedGeneration: UInt64
    ) -> MacArtifactCleanupRoot? {
        guard running,
              generation == expectedGeneration,
              let current = candidates[candidate.match.id],
              current.rootID == candidate.rootID,
              current.match == candidate.match,
              Date().timeIntervalSince(current.lastActivity) >= quietPeriod,
              let root = activeRoots[candidate.rootID],
              root.url.standardizedFileURL == candidate.match.rootURL.standardizedFileURL,
              store.configuration.roots.contains(where: { $0.id == candidate.rootID }),
              root.isOnOriginalVolume else {
            return nil
        }
        return root
    }

    func updateCandidate(
        _ candidate: PendingCandidate,
        outcome: FingerprintOutcome,
        root: MacArtifactCleanupRoot
    ) -> RunSummary {
        var summary = RunSummary(matched: 1)
        if let fingerprint = outcome.fingerprint,
           fingerprint == candidate.match.fingerprint {
            let mode = store.configuration.mode(for: root)
            let result = MacArtifactCleaner.apply(candidate.match, mode: mode)
            summary.record(result, match: candidate.match)
            if result == .previewed {
                candidates[candidate.match.id]?.automaticPreviewCompleted = true
            } else if result != .changedSinceScan {
                candidates.removeValue(forKey: candidate.match.id)
            } else {
                candidates[candidate.match.id]?.lastActivity = Date()
            }
        } else if let fingerprint = outcome.fingerprint {
            candidates[candidate.match.id] = PendingCandidate(
                rootID: candidate.rootID,
                match: MacArtifactMatch(
                    url: candidate.match.url,
                    rootURL: candidate.match.rootURL,
                    rootDevice: candidate.match.rootDevice,
                    kind: candidate.match.kind,
                    fingerprint: fingerprint
                ),
                lastActivity: Date()
            )
            summary.skipped += 1
            summary.details.append("Changed while waiting: \(candidate.match.url.path)")
        } else {
            candidates.removeValue(forKey: candidate.match.id)
            summary.skipped += 1
            let failure = outcome.failure ?? "Could not verify the item."
            summary.details.append("\(candidate.match.url.path): \(failure)")
        }
        return summary
    }

    func recordSummaries(
        _ summaries: [UUID: RunSummary],
        roots: [UUID: MacArtifactCleanupRoot]
    ) -> [String] {
        var notificationLines: [String] = []
        for rootID in summaries.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let root = roots[rootID], let summary = summaries[rootID] else { continue }
            store.record(summary.historyEntry(root: root, mode: store.configuration.mode(for: root)))
            notificationLines.append(
                "\(summary.removed) removed from \(root.url.lastPathComponent); \(summary.skipped) skipped"
            )
        }
        return notificationLines
    }
}

@MainActor
final class MacArtifactCleanupCandidateLifecycle {
    struct PreviewContext {
        let root: MacArtifactCleanupRoot
        let generation: UInt64
    }

    private let state: MacArtifactCleanupCandidateState
    private let fingerprintReader: MacArtifactCleanupProcessor.FingerprintReader
    private var processingToken: UUID?
    private var candidateFingerprintTask: Task<FingerprintOutcome, Never>?

    var onChange: (() -> Void)?
    var onNotification: ((String, String) -> Void)?
    var isRunning: Bool { state.isRunning }

    init(
        store: MacArtifactCleanupStore,
        quietPeriod: TimeInterval,
        fingerprintReader: @escaping MacArtifactCleanupProcessor.FingerprintReader
    ) {
        state = MacArtifactCleanupCandidateState(store: store, quietPeriod: quietPeriod)
        self.fingerprintReader = fingerprintReader
    }

    func start(roots: [MacArtifactCleanupRoot]) {
        state.start(roots: roots)
    }

    func stop() {
        state.stop()
        cancelCandidateProcessing()
    }

    func updateRoots(_ roots: [MacArtifactCleanupRoot]) {
        state.updateRoots(roots)
        cancelCandidateProcessing()
    }

    func isCurrent(_ root: MacArtifactCleanupRoot) -> Bool {
        state.isCurrent(root)
    }

    func previewContext(rootID: UUID) throws -> PreviewContext {
        try state.previewContext(rootID: rootID)
    }

    func completePreview(
        _ result: MacArtifactScanResult,
        context: PreviewContext,
        registerCandidates: Bool
    ) throws -> MacArtifactScanResult {
        let result = try state.completePreview(result, context: context, registerCandidates: registerCandidates)
        if registerCandidates { onChange?() }
        return result
    }

    @discardableResult
    func applyManually(
        _ matches: [MacArtifactMatch],
        rootID: UUID,
        mode: MacArtifactRemovalMode
    ) -> MacArtifactCleanupHistoryEntry? {
        guard processingToken == nil,
              let entry = state.applyManually(matches, rootID: rootID, mode: mode) else {
            return nil
        }
        notify(entry)
        onChange?()
        return entry
    }

    func register(
        _ matches: [MacArtifactMatch],
        foundUnder scannedRoot: MacArtifactCleanupRoot
    ) {
        _ = state.register(matches, foundUnder: scannedRoot)
        onChange?()
    }

    func markActivity(at path: String) -> Bool {
        state.markActivity(at: path)
    }

    func processMatureCandidates() async {
        guard processingToken == nil, let run = state.nextRun() else { return }
        let token = UUID()
        processingToken = token
        await process(run.candidates, token: token, generation: run.generation)
    }

    private func process(
        _ due: [PendingCandidate],
        token: UUID,
        generation expectedGeneration: UInt64
    ) async {
        var summaries: [UUID: RunSummary] = [:]
        var rootsForSummary: [UUID: MacArtifactCleanupRoot] = [:]
        for candidate in due {
            guard let validation = await validateCandidate(
                candidate,
                token: token,
                generation: expectedGeneration
            ) else { return }
            summaries[candidate.rootID, default: RunSummary()].merge(
                state.updateCandidate(candidate, outcome: validation.outcome, root: validation.root)
            )
            rootsForSummary[candidate.rootID] = validation.root
        }

        let notificationLines = state.recordSummaries(summaries, roots: rootsForSummary)
        finishProcessing(token: token)
        if !notificationLines.isEmpty {
            onNotification?("Mac cleanup complete", notificationLines.joined(separator: ". "))
        }
        onChange?()
    }

    private func validateCandidate(
        _ candidate: PendingCandidate,
        token: UUID,
        generation expectedGeneration: UInt64
    ) async -> (root: MacArtifactCleanupRoot, outcome: FingerprintOutcome)? {
        let fingerprintReader = self.fingerprintReader
        let worker = Task.detached(priority: .utility) {
            do {
                return FingerprintOutcome(
                    fingerprint: try await fingerprintReader(candidate.match),
                    failure: nil
                )
            } catch {
                return FingerprintOutcome(fingerprint: nil, failure: error.localizedDescription)
            }
        }
        candidateFingerprintTask = worker
        let outcome = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled,
              processingToken == token,
              let root = state.validatedRoot(for: candidate, expectedGeneration: expectedGeneration) else {
            finishProcessing(token: token)
            return nil
        }
        candidateFingerprintTask = nil
        return (root, outcome)
    }

    private func finishProcessing(token: UUID) {
        guard processingToken == token else { return }
        processingToken = nil
        candidateFingerprintTask = nil
    }

    private func cancelCandidateProcessing() {
        candidateFingerprintTask?.cancel()
        candidateFingerprintTask = nil
        processingToken = nil
    }

    private func notify(_ entry: MacArtifactCleanupHistoryEntry) {
        let folderName = URL(fileURLWithPath: entry.rootPath).lastPathComponent
        onNotification?(
            "Mac cleanup complete",
            "\(entry.removedCount) removed; \(entry.skippedCount) skipped from \(folderName)."
        )
    }
}
