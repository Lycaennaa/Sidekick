import AppKit

@MainActor
final class ClipboardImageConversionController {
    enum Result: Equatable {
        case converted(URL)
        case alreadyOutputFormat
        case noImage
        case unavailable
        case failed
        case stale
        case cancelled
    }

    private let pasteboard: any PasteboardAccess
    private let onMessage: (String) -> Void
    private let worker: ClipboardImageConversionWorker
    private let fileURLReader: any PasteboardFileURLReading
    private let payloadReader: any PasteboardPayloadReading
    private let outputFormat: () -> ClipboardImageFormat
    private let installer: ClipboardImagePasteboardInstaller
    private var captureTask: Task<Void, Never>?

    init(
        pasteboard: any PasteboardAccess = NSPasteboard.general,
        expirationInterval: TimeInterval = 60,
        outputDirectory: URL = ClipboardImageConversionPolicy.defaultOutputDirectory,
        outputFormat: @escaping () -> ClipboardImageFormat = { .webP },
        worker: ClipboardImageConversionWorker = ClipboardImageConversionWorker(),
        fileURLReader: any PasteboardFileURLReading = SystemPasteboardFileURLReader(),
        payloadReader: any PasteboardPayloadReading = SystemPasteboardPayloadReader(),
        onConverted: @escaping (URL, Int) -> Void = { _, _ in },
        onMessage: @escaping (String) -> Void
    ) {
        self.pasteboard = pasteboard
        self.onMessage = onMessage
        self.worker = worker
        self.fileURLReader = fileURLReader
        self.outputFormat = outputFormat
        self.payloadReader = payloadReader
        installer = ClipboardImagePasteboardInstaller(
            pasteboard: pasteboard,
            expirationInterval: expirationInterval,
            outputDirectory: outputDirectory,
            fileURLReader: fileURLReader,
            payloadReader: payloadReader,
            onConverted: onConverted,
            onMessage: onMessage
        )
    }

    func convertClipboardImage(
        skipAlreadyOutputFormatFiles: Bool = false,
        completion: @escaping (Result) -> Void = { _ in }
    ) {
        guard !installer.isTerminated else {
            completion(.cancelled)
            return
        }
        let requestToken = installer.beginRequest()
        captureTask?.cancel()
        worker.cancelAll()
        let pasteboard = self.pasteboard
        let format = outputFormat()
        captureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.captureAndEnqueue(
                pasteboard: pasteboard,
                requestToken: requestToken,
                outputFormat: format,
                skipAlreadyOutputFormatFiles: skipAlreadyOutputFormatFiles,
                completion: completion
            )
        }
    }

    func terminate() {
        guard !installer.isTerminated else { return }
        installer.terminate()
        captureTask?.cancel()
        captureTask = nil
        worker.cancelAll()
    }

    func waitForTerminationCleanup() async {
        await installer.waitForTerminationCleanup()
    }

    func cancelPendingConversion() {
        installer.cancelPendingConversion()
        captureTask?.cancel()
        worker.cancelAll()
    }

}
extension ClipboardImageConversionController {
    private func captureAndEnqueue(
        pasteboard: any PasteboardAccess,
        requestToken: UInt64,
        outputFormat: ClipboardImageFormat,
        skipAlreadyOutputFormatFiles: Bool,
        completion: @escaping (Result) -> Void
    ) async {
        let capture = await ClipboardImageConversionPasteboardCapture.captureImage(
            from: pasteboard,
            outputFormat: outputFormat,
            skipAlreadyOutputFormatFiles: skipAlreadyOutputFormatFiles,
            fileURLReader: fileURLReader,
            payloadReader: payloadReader
        )
        guard !Task.isCancelled, installer.isRequestCurrent(token: requestToken) else {
            completion(.stale)
            return
        }
        guard let captured = source(from: capture, completion: completion) else { return }
        guard installer.isCurrent(token: requestToken, sourceChangeCount: captured.changeCount) else {
            completion(.stale)
            return
        }

        let installer = self.installer
        worker.enqueue(
            source: captured.source,
            outputDirectory: installer.outputDirectory,
            format: outputFormat,
            cleanup: { url in
                installer.removeGeneratedFile(at: url)
            },
            completion: { [weak self, installer] result in
                guard let self else {
                    if case let .success(url) = result {
                        installer.removeGeneratedFile(at: url)
                    }
                    return
                }
                self.handleWorkerResult(
                    result,
                    installer: installer,
                    captured: captured,
                    requestToken: requestToken,
                    completion: completion
                )
            }
        )
    }

    private func source(
        from capture: ClipboardImageConversionCapture,
        completion: @escaping (Result) -> Void
    ) -> ClipboardImageConversionCapturedSource? {
        switch capture {
        case .alreadyOutputFormat:
            completion(.alreadyOutputFormat)
        case let .source(captured):
            return captured
        case .noImage:
            onMessage("No image to convert")
            completion(.noImage)
        case .unavailable:
            onMessage("Clipboard image unavailable")
            completion(.unavailable)
        case .failed:
            onMessage("Couldn’t convert clipboard image")
            completion(.failed)
        case .stale:
            installer.discardLeaseIfGenerationChanged()
            completion(.stale)
        }
        return nil
    }

    private func handleWorkerResult(
        _ result: ClipboardImageConversionWorker.Result,
        installer: ClipboardImagePasteboardInstaller,
        captured: ClipboardImageConversionCapturedSource,
        requestToken: UInt64,
        completion: @escaping (Result) -> Void
    ) {
        guard installer.isCurrent(token: requestToken, sourceChangeCount: captured.changeCount) else {
            if case let .success(url) = result {
                installer.removeGeneratedFile(at: url)
            }
            installer.discardLeaseIfGenerationChanged()
            completion(.stale)
            return
        }

        switch result {
        case let .success(url):
            installer.enqueueInstallation(
                url: url,
                snapshot: captured.snapshot,
                token: requestToken,
                sourceChangeCount: captured.changeCount,
                completion: { result in
                    switch result {
                    case let .installed(url):
                        completion(.converted(url))
                    case .failed:
                        completion(.failed)
                    case .stale:
                        completion(.stale)
                    }
                }
            )
        case let .failure(failure):
            if failure == .conversion(.invalidImage) {
                onMessage("No image to convert")
                completion(.noImage)
            } else {
                onMessage("Couldn’t convert clipboard image")
                completion(.failed)
            }
        case .cancelled:
            completion(.cancelled)
        }
    }
}
