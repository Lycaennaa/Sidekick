import Foundation

@MainActor
final class MacArtifactCleanupProcessor {
    typealias FingerprintReader = @Sendable (MacArtifactMatch) async throws -> MacArtifactFingerprint

    static let quietPeriod: TimeInterval = 30

    var onChange: (() -> Void)?
    var onRootChanged: (() -> Void)?

    private let store: MacArtifactCleanupStore
    private let scanner = MacArtifactCleanupScanEngine()
    private let notifier: MacArtifactCleanupNotifier
    private let candidateLifecycle: MacArtifactCleanupCandidateLifecycle
    private var timer: Timer?
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
        let candidateLifecycle = MacArtifactCleanupCandidateLifecycle(
            store: store,
            quietPeriod: quietPeriod,
            fingerprintReader: fingerprintReader
        )
        self.candidateLifecycle = candidateLifecycle
        candidateLifecycle.onChange = { [weak self] in self?.onChange?() }
        candidateLifecycle.onNotification = { [weak self] title, body in
            self?.notify(title: title, body: body)
        }
        scanner.onScanResult = { [weak self] root, result in self?.didScan(root, result: result) }
        scanner.onScanFailure = { [weak self] root, message in self?.didFailScan(root, message: message) }
        scanner.onMatch = { [weak self] root, match in self?.didFind(match, under: root) }
        scanner.onInspectionFailure = { [weak self] root, url, message in
            self?.didFailInspection(root, url: url, message: message)
        }
        scanner.onRootChanged = { [weak self] in self?.onRootChanged?() }
    }

    func start(roots: [MacArtifactCleanupRoot]) {
        guard !candidateLifecycle.isRunning else { return }
        candidateLifecycle.start(roots: roots)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleTimerProcessing() }
        }
        scanner.start(roots: roots)
        onChange?()
    }

    func stop() {
        guard candidateLifecycle.isRunning else { return }
        candidateLifecycle.stop()
        timer?.invalidate()
        timer = nil
        timerTask?.cancel()
        scanner.stop()
        notifier.stop()
        onChange?()
    }

    func waitForBackgroundScans() async {
        if let timerTask { await timerTask.value }
        await scanner.waitForBackgroundScans()
    }

    private func scheduleTimerProcessing() {
        guard candidateLifecycle.isRunning, timerTask == nil else { return }
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
        guard candidateLifecycle.isRunning else { return }
        candidateLifecycle.updateRoots(roots)
        scanner.updateRoots(roots)
        onChange?()
    }

    func receive(_ events: [MacArtifactFileEvent]) {
        guard candidateLifecycle.isRunning else { return }
        scanner.receive(events.filter { event in
            let activityObserved = candidateLifecycle.markActivity(at: event.path)
            return !activityObserved
                || MacArtifactScanner.mayMatch(URL(fileURLWithPath: event.path).lastPathComponent)
        })
    }

    func preview(rootID: UUID, registerCandidates: Bool = false) async throws -> MacArtifactScanResult {
        let context = try candidateLifecycle.previewContext(rootID: rootID)
        let result = try await scanner.preview(rootID: rootID)
        return try candidateLifecycle.completePreview(
            result,
            context: context,
            registerCandidates: registerCandidates
        )
    }

    @discardableResult
    func applyManually(
        _ matches: [MacArtifactMatch],
        rootID: UUID,
        mode: MacArtifactRemovalMode
    ) -> MacArtifactCleanupHistoryEntry? {
        candidateLifecycle.applyManually(matches, rootID: rootID, mode: mode)
    }

    func processMatureCandidates() async {
        await candidateLifecycle.processMatureCandidates()
    }
}

extension MacArtifactCleanupProcessor {
    private func didScan(_ root: MacArtifactCleanupRoot, result: MacArtifactScanResult) {
        guard candidateLifecycle.isCurrent(root) else { return }
        candidateLifecycle.register(result.matches, foundUnder: root)
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
        guard candidateLifecycle.isCurrent(root) else { return }
        recordIssue(root, details: [message])
    }

    private func didFind(_ match: MacArtifactMatch, under root: MacArtifactCleanupRoot) {
        guard candidateLifecycle.isCurrent(root),
              match.rootURL.standardizedFileURL == root.url.standardizedFileURL else {
            return
        }
        candidateLifecycle.register([match], foundUnder: root)
    }

    private func didFailInspection(_ root: MacArtifactCleanupRoot, url: URL, message: String) {
        guard candidateLifecycle.isCurrent(root) else { return }
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
        guard candidateLifecycle.isRunning else { return }
        notifier.send(
            title: title,
            body: body,
            isCurrent: { [weak self] in self?.candidateLifecycle.isRunning == true }
        )
    }
}
