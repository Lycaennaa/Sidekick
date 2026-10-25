import AppKit

@MainActor
final class ClipboardAutoImageConversionController: NSObject {
    static let pollInterval: TimeInterval = 0.25

    private let settings: AppSettings
    private let pasteboard: NSPasteboard
    private let onCaptureResult: (ClipboardImageConversionCapture, ClipboardImageFormat) -> Void
    private let fileURLReader: any PasteboardFileURLReading
    private let payloadReader: any PasteboardPayloadReading

    private var pollTimer: Timer?
    private var changeObservation = ClipboardChangeObservationState()
    private var detectionTask: Task<ClipboardImageConversionCapture, Never>?
    private var detectionGeneration: UInt64?
    private var observedOutputFormat: ClipboardImageFormat?
    private var enabled = false
    private var started = false

    init(
        settings: AppSettings,
        pasteboard: NSPasteboard = .general,
        fileURLReader: any PasteboardFileURLReading = SystemPasteboardFileURLReader(),
        payloadReader: any PasteboardPayloadReading = SystemPasteboardPayloadReader(),
        onCaptureResult: @escaping (ClipboardImageConversionCapture, ClipboardImageFormat) -> Void
    ) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.fileURLReader = fileURLReader
        self.payloadReader = payloadReader
        self.onCaptureResult = onCaptureResult
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        enabled = settings.automaticImageConversionEnabled
        observedOutputFormat = settings.imageOutputFormat
        changeObservation.seed(changeCount: pasteboard.changeCount)
        if enabled {
            startPollTimer()
        }
    }

    func applySettings() {
        guard started else { return }
        synchronizeEnabledState()
    }
    func cancelPendingDetection() {
        detectionTask?.cancel()
        detectionTask = nil
        detectionGeneration = nil
        changeObservation.seed(changeCount: pasteboard.changeCount)
    }

    func terminate() {
        guard started else { return }
        started = false
        changeObservation.invalidate()
        detectionTask?.cancel()
        detectionTask = nil
        detectionGeneration = nil
        stopPollTimer()
    }

    func poll() async {
        guard started else { return }
        synchronizeEnabledState()
        guard enabled else { return }

        let changeCount = pasteboard.changeCount
        let previousGeneration = changeObservation.generation
        guard let generation = changeObservation.observe(changeCount: changeCount) else {
            if changeObservation.generation != previousGeneration {
                detectionTask?.cancel()
                detectionTask = nil
                detectionGeneration = nil
            }
            return
        }

        let outputFormat = settings.imageOutputFormat
        let task = Task { @MainActor [weak self] in
            guard let self else { return ClipboardImageConversionCapture.stale }
            return await ClipboardImageConversionPasteboardCapture.captureImage(
                from: self.pasteboard,
                outputFormat: outputFormat,
                skipAlreadyOutputFormatFiles: true,
                fileURLReader: self.fileURLReader,
                payloadReader: self.payloadReader
            )
        }
        detectionTask = task
        detectionGeneration = generation

        let capture = await task.value
        guard detectionGeneration == generation else { return }
        let shouldDeliver = !task.isCancelled
            && started
            && enabled
            && settings.automaticImageConversionEnabled
            && settings.imageOutputFormat == outputFormat
            && pasteboard.changeCount == changeCount
            && changeObservation.isCurrentGeneration(generation)
        detectionTask = nil
        detectionGeneration = nil
        guard shouldDeliver else { return }
        switch capture {
        case .source, .unavailable, .failed:
            onCaptureResult(capture, outputFormat)
        case .alreadyOutputFormat, .noImage, .stale:
            break
        }
    }
    func acknowledgeConvertedChange(changeCount: Int) {
        guard pasteboard.changeCount == changeCount else { return }
        changeObservation.seed(changeCount: changeCount)
    }

    @objc private func pollTimerFired() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.poll()
        }
    }
    private func synchronizeEnabledState() {
        let shouldEnable = settings.automaticImageConversionEnabled
        let outputFormat = settings.imageOutputFormat
        let outputFormatChanged = observedOutputFormat.map { $0 != outputFormat } ?? false
        observedOutputFormat = outputFormat

        guard shouldEnable != enabled else {
            guard enabled, outputFormatChanged, detectionTask != nil else { return }
            detectionTask?.cancel()
            detectionTask = nil
            detectionGeneration = nil
            changeObservation.rearm(changeCount: pasteboard.changeCount)
            return
        }
        enabled = shouldEnable
        detectionTask?.cancel()
        detectionTask = nil
        detectionGeneration = nil
        changeObservation.seed(changeCount: pasteboard.changeCount)
        if enabled {
            startPollTimer()
        } else {
            stopPollTimer()
        }
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

}
