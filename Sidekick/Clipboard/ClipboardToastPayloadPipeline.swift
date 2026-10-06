import AppKit

struct ClipboardImagePreviewAction {
    let request: ClipboardImageEnrichmentRequest
    let isCurrent: @MainActor @Sendable () -> Bool
}

@MainActor
final class ClipboardToastPayloadPipeline {
    typealias ObservationValidity = @MainActor @Sendable (Int) -> Bool
    typealias PayloadValidity = @MainActor @Sendable (UInt64) -> Bool
    typealias ImagePreviewHandler = @MainActor (ClipboardImagePreviewAction) -> Void

    private let settings: AppSettings
    private let pasteboard: NSPasteboard
    private let screenshotMetadataRegistry: ScreenshotClipboardMetadataRegistry
    private let imageWorker: any ClipboardImageEnriching
    private let fileURLReader: any PasteboardFileURLReading
    private let payloadReader: any PasteboardPayloadReading
    private let tokenizer: ClipboardTokenizer
    private let onToastChange: (ToastModel?) -> Void
    private let onToastUpdate: (ToastModel) -> Void
    private let onImagePreview: ImagePreviewHandler?

    private var observationState = ClipboardToastObservationState()
    private var currentToast: ToastModel?
    private var currentToastChangeCount: Int?
    private var currentSourceApplication: ClipboardSourceApplication?
    private var seedTask: Task<Void, Never>?
    private var payloadTask: Task<Void, Never>?
    private var payloadPresentationGeneration: UInt64 = 0
    private var seedGeneration: UInt64 = 0

    init(
        settings: AppSettings,
        pasteboard: NSPasteboard,
        screenshotMetadataRegistry: ScreenshotClipboardMetadataRegistry = ScreenshotClipboardMetadataRegistry(),
        imageWorker: any ClipboardImageEnriching,
        fileURLReader: any PasteboardFileURLReading,
        payloadReader: any PasteboardPayloadReading,
        onToastChange: @escaping (ToastModel?) -> Void,
        onToastUpdate: @escaping (ToastModel) -> Void,
        onImagePreview: ImagePreviewHandler? = nil,
        tokenizer: ClipboardTokenizer = ClipboardTokenizer()
    ) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.imageWorker = imageWorker
        self.screenshotMetadataRegistry = screenshotMetadataRegistry
        self.fileURLReader = fileURLReader
        self.payloadReader = payloadReader
        self.onToastChange = onToastChange
        self.onToastUpdate = onToastUpdate
        self.onImagePreview = onImagePreview
        self.tokenizer = tokenizer
    }

    @discardableResult
    func cancelPendingAcknowledgment() -> UInt64 {
        seedGeneration &+= 1
        seedTask?.cancel()
        seedTask = nil
        return seedGeneration
    }

    func cancelPendingPayloadOperation() {
        _ = beginPayloadOperation()
    }

    private func beginPayloadOperation() -> UInt64 {
        payloadPresentationGeneration &+= 1
        payloadTask?.cancel()
        payloadTask = nil
        return payloadPresentationGeneration
    }

    func toastDidDismiss(generation: UInt64) {
        guard currentToast?.generation == generation else { return }
        currentToast = nil
        currentToastChangeCount = nil
        currentSourceApplication = nil
        imageWorker.cancelAll()
        cancelPendingPayloadOperation()
    }

    func acknowledgeClipboardChange(
        _ changeCount: Int,
        isCurrent: @escaping ObservationValidity
    ) {
        let sourceItems = pasteboard.pasteboardItems ?? []
        let items = Array(sourceItems.prefix(ClipboardPayloadClassifier.maximumFileItems))
        observationState.acknowledge(fingerprint: nil)
        let generation = cancelPendingAcknowledgment()
        let payloadReader = self.payloadReader
        seedTask = Task { @MainActor [weak self] in
            let fingerprint = await ClipboardPayloadClassifier.textFingerprint(
                items: items,
                payloadReader: payloadReader
            )
            guard let self,
                  !Task.isCancelled,
                  self.seedGeneration == generation,
                  self.pasteboard.changeCount == changeCount,
                  isCurrent(changeCount) else {
                return
            }
            self.observationState.acknowledge(fingerprint: fingerprint)
            self.seedTask = nil
        }
    }

    func matchesFile(_ url: URL, changeCount: Int) async -> Bool {
        cancelPendingPayloadOperation()
        let generation = seedGeneration
        guard !Task.isCancelled, pasteboard.changeCount == changeCount else { return false }
        let exactURL = await PasteboardSnapshot.exactFileURL(
            from: pasteboard,
            maximumItems: PasteboardSnapshotPolicy.maximumItems,
            maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem,
            expectedChangeCount: changeCount,
            fileURLReader: fileURLReader
        )
        return !Task.isCancelled
            && seedGeneration == generation
            && exactURL == url.standardizedFileURL
            && pasteboard.changeCount == changeCount
    }

    func reseed(
        sourceApplication: ClipboardSourceApplication?,
        isCurrent: @escaping ObservationValidity
    ) {
        let changeCount = pasteboard.changeCount
        let sourceItems = pasteboard.pasteboardItems ?? []
        let items = Array(sourceItems.prefix(ClipboardPayloadClassifier.maximumFileItems))
        observationState.reseed(sourceApplication: sourceApplication, fingerprint: nil)
        let generation = cancelPendingAcknowledgment()
        let payloadReader = self.payloadReader
        seedTask = Task { @MainActor [weak self] in
            let fingerprint = await ClipboardPayloadClassifier.textFingerprint(
                items: items,
                payloadReader: payloadReader
            )
            guard let self,
                  !Task.isCancelled,
                  self.seedGeneration == generation,
                  self.pasteboard.changeCount == changeCount,
                  isCurrent(changeCount) else {
                return
            }
            self.observationState.reseed(
                sourceApplication: sourceApplication,
                fingerprint: fingerprint
            )
            self.seedTask = nil
        }
    }

    func markSourceApplicationChanged() {
        observationState.markSourceApplicationChanged()
    }

    func sourceApplicationForChange(
        current: ClipboardSourceApplication?,
        changedDuringSample: Bool
    ) -> ClipboardSourceApplication? {
        observationState.sourceApplicationForChange(
            current: current,
            changedDuringSample: changedDuringSample
        )
    }

    func recordChangedPasteboard(
        sourceApplication: ClipboardSourceApplication?,
        sourceBundleIdentifierForExclusion: String?,
        previousChangeCount: Int?,
        currentChangeCount: Int
    ) {
        cancelPendingPayloadOperation()
        let items = Array(
            (pasteboard.pasteboardItems ?? []).prefix(ClipboardPayloadClassifier.maximumFileItems)
        )
        let containsTransientMarker = ClipboardPayloadClassifier.shouldSuppressToast(items: items)
        observationState.recordChange(
            sourceApplication: sourceApplication,
            sourceBundleIdentifierForExclusion: sourceBundleIdentifierForExclusion,
            previousChangeCount: previousChangeCount,
            currentChangeCount: currentChangeCount,
            containsTransientMarker: containsTransientMarker
        )
    }

    func processStablePasteboard(
        changeCount: Int,
        generation: UInt64,
        isCurrent: @escaping PayloadValidity
    ) {
        let attribution = observationState.consumeAttribution()
        let sourceItems = pasteboard.pasteboardItems ?? []
        guard !sourceItems.isEmpty else {
            guard pasteboard.changeCount == changeCount else { return }
            observationState.completeStableObservation(fingerprint: nil)
            clearCurrentToast()
            return
        }

        let items = Array(sourceItems.prefix(ClipboardPayloadClassifier.maximumFileItems))
        let presentationGeneration = beginPayloadOperation()
        let screenshotDynamicRange = screenshotMetadataRegistry.dynamicRange(
            forChangeCount: changeCount
        )
        payloadTask = Task { @MainActor [weak self] in
            await self?.processStablePasteboardPayload(
                PayloadOperation(
                    items: items,
                    totalItemCount: sourceItems.count,
                    changeCount: changeCount,
                    generation: generation,
                    presentationGeneration: presentationGeneration,
                    attribution: attribution,
                    isCurrent: isCurrent,
                    screenshotDynamicRange: screenshotDynamicRange
                )
            )
        }
    }

    func clearCurrentToast() {
        cancelPendingPayloadOperation()
        imageWorker.cancelAll()
        currentSourceApplication = nil
        currentToastChangeCount = nil
        guard currentToast != nil else { return }
        currentToast = nil
        onToastChange(nil)
    }

    private func clipboardFooter(
        metadata: String?,
        sourceApplication: ClipboardSourceApplication?,
        sameLine: Bool
    ) -> String? {
        let sourceFooter = sourceApplication?.name
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : "Copied from \($0)" }
        return [
            metadata?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            sourceFooter
        ]
        .compactMap(\.self)
        .joined(separator: sameLine ? " • " : "\n")
        .nilIfEmpty
    }

    private func imageEnrichmentRequest(
        from classification: ClipboardPayloadClassification
    ) -> ClipboardImageEnrichmentRequest? {
        switch classification {
        case let .files(_, _, _, _, _, _, request):
            return request
        case let .image(_, _, request, _):
            return request
        case .text, .generic, .unavailable:
            return nil
        }
    }

    private static func toastPresentationStyle(
        for kind: ClipboardImageEnrichmentKind
    ) -> ToastPresentationStyle {
        switch kind {
        case .data:
            return .image
        case .localFile:
            return .files
        }
    }

    private func applyImageEnrichment(
        _ enrichment: ClipboardImageEnrichment,
        isCurrent: @escaping PayloadValidity
    ) {
        guard isCurrent(enrichment.generation),
              let currentModel = currentToast,
              currentModel.generation == enrichment.generation,
              currentModel.presentationStyle == Self.toastPresentationStyle(for: enrichment.kind)
        else {
            return
        }

        let thumbnail = NSImage(
            cgImage: enrichment.thumbnail,
            size: NSSize(
                width: enrichment.thumbnail.width,
                height: enrichment.thumbnail.height
            )
        )
        let model = ToastModel(
            generation: enrichment.generation,
            presentationStyle: currentModel.presentationStyle,
            summary: currentModel.summary,
            detail: currentModel.detail,
            icon: thumbnail,
            showsImagePreview: true,
            onUserAction: currentModel.onUserAction,
            footer: clipboardFooter(
                metadata: enrichment.imageFooter,
                sourceApplication: currentSourceApplication,
                sameLine: false
            )
        )
        currentToast = model
        onToastUpdate(model)
    }
}
extension ClipboardToastPayloadPipeline {
    private struct PayloadOperation {
        let items: [NSPasteboardItem]
        let totalItemCount: Int
        let changeCount: Int
        let generation: UInt64
        let presentationGeneration: UInt64
        let attribution: ClipboardToastObservationState.Attribution?
        let isCurrent: PayloadValidity
        let screenshotDynamicRange: ClipboardScreenshotDynamicRange?
    }

    private func processStablePasteboardPayload(_ operation: PayloadOperation) async {
        guard isValid(operation) else { return }
        let suppressesToast = ClipboardPayloadClassifier.shouldSuppressToast(items: operation.items)
        guard isValid(operation) else { return }
        guard !suppressesToast else {
            clearCurrentToast()
            return
        }
        guard let analysis = await analyze(operation), isValid(operation) else { return }

        let textFingerprint = analysis.textFingerprint
        if observationState.shouldSuppressTransientRestore(current: textFingerprint) {
            observationState.resolveTransientRestore()
            clearCurrentToast()
            return
        }
        observationState.resolveTransientRestore()
        guard !shouldSuppressClipboardToast(
            sourceApplicationBundleIdentifier: operation.attribution?.sourceBundleIdentifierForExclusion,
            excludedBundleIdentifiers: settings.excludedToastApplicationBundleIdentifiers
        ) else {
            observationState.completeStableObservation(fingerprint: textFingerprint)
            clearCurrentToast()
            return
        }

        observationState.completeStableObservation(fingerprint: textFingerprint)
        publish(analysis, operation: operation)
    }

    private func isValid(_ operation: PayloadOperation) -> Bool {
        !Task.isCancelled
            && operation.isCurrent(operation.generation)
            && payloadPresentationGeneration == operation.presentationGeneration
            && pasteboard.changeCount == operation.changeCount
    }

    private func analyze(_ operation: PayloadOperation) async -> ClipboardPayloadAnalysis? {
        imageWorker.cancelAll()
        let analysis = await ClipboardPayloadClassifier.analyze(
            items: operation.items,
            generation: operation.generation,
            totalItemCount: operation.totalItemCount,
            fileURLReader: fileURLReader,
            payloadReader: payloadReader,
            tokenizer: tokenizer,
            screenshotDynamicRange: operation.screenshotDynamicRange
        )
        guard isValid(operation) else { return nil }
        return analysis
    }

    private func publish(
        _ analysis: ClipboardPayloadAnalysis,
        operation: PayloadOperation
    ) {
        let sourceApplication = operation.attribution?.sourceApplication
        let imageRequest = imageEnrichmentRequest(from: analysis.classification)
        var model = ClipboardPayloadPresentation.toastModel(
            from: analysis.classification,
            textMetrics: analysis.textMetrics
        )
        model.footer = clipboardFooter(
            metadata: model.footer,
            sourceApplication: sourceApplication,
            sameLine: model.presentationStyle == .text
        )
        if let imageRequest, let onImagePreview {
            let expectedGeneration = model.generation
            let isToastCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self else { return false }
                return self.currentToast?.generation == expectedGeneration
                    && self.currentToastChangeCount == operation.changeCount
                    && self.pasteboard.changeCount == operation.changeCount
            }
            let isActionCurrent: @MainActor @Sendable () -> Bool = { [weak self] in
                self?.pasteboard.changeCount == operation.changeCount
            }
            model.onUserAction = {
                guard isToastCurrent() else { return }
                onImagePreview(
                    ClipboardImagePreviewAction(
                        request: imageRequest,
                        isCurrent: isActionCurrent
                    )
                )
            }
        }
        currentSourceApplication = sourceApplication
        currentToastChangeCount = operation.changeCount
        currentToast = model
        onToastChange(model)

        if let request = imageRequest {
            imageWorker.enqueue(request) { [weak self] enrichment in
                self?.applyImageEnrichment(enrichment, isCurrent: operation.isCurrent)
            }
        }
    }
}
