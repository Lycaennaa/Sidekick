import AppKit

@MainActor
final class ClipboardToastController: NSObject {
    static let pollInterval: TimeInterval = 0.25

    private let settings: AppSettings
    private let pasteboard: NSPasteboard
    private let now: () -> Date
    private let sourceApplication: () -> ClipboardSourceApplication?
    private let workspaceNotificationCenter: NotificationCenter
    private let onStateChange: (ClipboardToastState.Status) -> Void
    private let payloadPipeline: ClipboardToastPayloadPipeline

    private var state: ClipboardToastState
    private var pollTimer: Timer?
    private var pauseTimer: Timer?
    private var started = false

    init(
        settings: AppSettings,
        pasteboard: NSPasteboard = .general,
        screenshotMetadataRegistry: ScreenshotClipboardMetadataRegistry = ScreenshotClipboardMetadataRegistry(),
        now: @escaping () -> Date = Date.init,
        sourceApplication: @escaping () -> ClipboardSourceApplication? = {
            guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
            return ClipboardSourceApplication(
                name: application.localizedName ?? application.bundleIdentifier,
                bundleIdentifier: application.bundleIdentifier
            )
        },
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        imageWorker: any ClipboardImageEnriching = ClipboardImageEnrichmentWorker(),
        fileURLReader: any PasteboardFileURLReading = SystemPasteboardFileURLReader(),
        payloadReader: any PasteboardPayloadReading = SystemPasteboardPayloadReader(),
        onStateChange: @escaping (ClipboardToastState.Status) -> Void = { _ in },
        onToastChange: @escaping (ToastModel?) -> Void = { _ in },
        onToastUpdate: @escaping (ToastModel) -> Void = { _ in },
        onImagePreview: ClipboardToastPayloadPipeline.ImagePreviewHandler? = nil,
        tokenizer: ClipboardTokenizer = ClipboardTokenizer()
    ) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.now = now
        self.sourceApplication = sourceApplication
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.payloadPipeline = ClipboardToastPayloadPipeline(
            settings: settings,
            pasteboard: pasteboard,
            screenshotMetadataRegistry: screenshotMetadataRegistry,
            imageWorker: imageWorker,
            fileURLReader: fileURLReader,
            payloadReader: payloadReader,
            onToastChange: onToastChange,
            onToastUpdate: onToastUpdate,
            onImagePreview: onImagePreview,
            tokenizer: tokenizer
        )
        self.onStateChange = onStateChange
        state = ClipboardToastState(enabled: settings.clipboardToastEnabled)
        super.init()
    }

    var status: ClipboardToastState.Status {
        state.status
    }

    func start() {
        guard !started else { return }
        started = true
        workspaceNotificationCenter.addObserver(
            self,
            selector: #selector(sourceApplicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        reconcile(forceReseed: true)
    }

    func applySettings() {
        guard state.setEnabled(settings.clipboardToastEnabled) else {
            onStateChange(state.status)
            return
        }
        if !settings.clipboardToastEnabled {
            clearCurrentToast()
        }
        reconcile(forceReseed: settings.clipboardToastEnabled)
    }

    func pause(for interval: TimeInterval?) {
        let deadline = interval.map { now().addingTimeInterval($0) }
        guard state.beginPause(until: deadline) else { return }
        clearCurrentToast()
        reconcile()
    }

    func resume() {
        guard state.resume() else { return }
        reconcile(forceReseed: true)
    }

    func addSuspension(_ reason: ClipboardToastState.SuspensionReason) {
        guard state.addSuspension(reason) else { return }
        clearCurrentToast()
        reconcile()
    }

    func removeSuspension(_ reason: ClipboardToastState.SuspensionReason) {
        guard state.removeSuspension(reason) else { return }
        reconcile(forceReseed: state.suspensionReasons.isEmpty)
    }

    func terminate() {
        state.terminate()
        cancelPendingAcknowledgment()
        cancelPendingPayloadOperation()
        workspaceNotificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        stopPollTimer()
        stopPauseTimer()
        clearCurrentToast()
        onStateChange(state.status)
    }

    @discardableResult
    func cancelPendingAcknowledgment() -> UInt64 {
        payloadPipeline.cancelPendingAcknowledgment()
    }

    func cancelPendingPayloadOperation() {
        payloadPipeline.cancelPendingPayloadOperation()
    }

    func toastDidDismiss(generation: UInt64) {
        payloadPipeline.toastDidDismiss(generation: generation)
    }

    func acknowledgeClipboardChange(_ changeCount: Int) {
        guard pasteboard.changeCount == changeCount else { return }
        cancelPendingPayloadOperation()
        state.seed(changeCount: changeCount)
        payloadPipeline.acknowledgeClipboardChange(
            changeCount,
            isCurrent: { [weak self] changeCount in
                self?.isCurrentObservation(changeCount) ?? false
            }
        )
    }

    func acknowledgeClipboardChange(_ changeCount: Int, matchingFile url: URL) async {
        guard await payloadPipeline.matchesFile(url, changeCount: changeCount) else { return }
        acknowledgeClipboardChange(changeCount)
    }

    private func reconcile(forceReseed: Bool = false) {
        let pauseExpired = state.expirePause(at: now())
        schedulePauseTimer()

        if started, state.status == .active {
            if forceReseed || pauseExpired || pollTimer == nil {
                stopPollTimer()
                cancelPendingPayloadOperation()
                seedPasteboardState()
                startPollTimer()
            }
        } else {
            cancelPendingAcknowledgment()
            cancelPendingPayloadOperation()
            stopPollTimer()
        }

        onStateChange(state.status)
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

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func schedulePauseTimer() {
        stopPauseTimer()
        guard case let .until(deadline) = state.pause else { return }

        let timer = Timer(
            timeInterval: max(0, deadline.timeIntervalSince(now())),
            target: self,
            selector: #selector(pauseTimerFired),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        pauseTimer = timer
    }

    private func stopPauseTimer() {
        pauseTimer?.invalidate()
        pauseTimer = nil
    }

    private func clearCurrentToast() {
        payloadPipeline.clearCurrentToast()
    }
    func dismissCurrentToast() {
        clearCurrentToast()
    }

    private func seedPasteboardState() {
        let changeCount = pasteboard.changeCount
        let source = sourceApplication()
        state.seed(changeCount: changeCount)
        payloadPipeline.reseed(
            sourceApplication: source,
            isCurrent: { [weak self] changeCount in
                self?.isCurrentObservation(changeCount) ?? false
            }
        )
    }

    @objc private func pollTimerFired() {
        poll()
    }

    func poll() {
        let changeCountBeforeSourceSample = pasteboard.changeCount
        let currentSourceApplication = sourceApplication()
        let changeCountAfterSourceSample = pasteboard.changeCount
        let sourceApplicationForChange = payloadPipeline.sourceApplicationForChange(
            current: currentSourceApplication,
            changedDuringSample: changeCountBeforeSourceSample != changeCountAfterSourceSample
        )
        let previousChangeCount = state.observedChangeCount
        let generation = state.observe(changeCount: changeCountAfterSourceSample)
        if previousChangeCount != changeCountAfterSourceSample {
            payloadPipeline.recordChangedPasteboard(
                sourceApplication: sourceApplicationForChange,
                sourceBundleIdentifierForExclusion: currentSourceApplication?.bundleIdentifier,
                previousChangeCount: previousChangeCount,
                currentChangeCount: changeCountAfterSourceSample
            )
            return
        }
        guard let generation else { return }
        payloadPipeline.processStablePasteboard(
            changeCount: changeCountAfterSourceSample,
            generation: generation,
            isCurrent: { [weak self] generation in
                self?.isCurrentPayload(generation) ?? false
            }
        )
    }

    private func isCurrentObservation(_ changeCount: Int) -> Bool {
        state.observedChangeCount == changeCount
    }

    private func isCurrentPayload(_ generation: UInt64) -> Bool {
        state.status == .active && state.isCurrentGeneration(generation)
    }

    @objc private func sourceApplicationDidActivate(_ notification: Notification) {
        payloadPipeline.markSourceApplicationChanged()
    }

    @objc private func pauseTimerFired() {
        pauseTimer = nil
        reconcile(forceReseed: true)
    }
}
