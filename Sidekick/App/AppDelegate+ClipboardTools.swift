import AppKit
import UniformTypeIdentifiers

private struct ConvertedImageToastContext {
    let url: URL
    let changeCount: Int
    let generation: UInt64
    let request: ClipboardImageEnrichmentRequest
    let presentationToken: UInt64
}
@MainActor
private enum ImageConversionRequest {
    case manual
    case automatic(ClipboardImageConversionCapturedSource, outputFormat: ClipboardImageFormat)

    var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
    }
}

extension AppDelegate {
    func syncClearURLsClipboardCleaner() {
        clipboardClearURLsController?.applySettings()
    }

    func handleClearURLsResult(_ result: ClipboardClearURLsResult) {
        switch result {
        case let .cleaned(changeCount):
            clipboardToastController?.dismissCurrentToast()
            clipboardToastController?.acknowledgeClipboardChange(changeCount)
        case .failed, .replacementFailed:
            presentUtilityToast(
                "Couldn’t clean clipboard",
                style: .text,
                symbolName: "link.badge.exclamationmark"
            )
        case .restoreFailed:
            presentUtilityToast(
                "Couldn’t restore clipboard",
                style: .text,
                symbolName: "link.badge.exclamationmark"
            )
        case .unchanged, .noText, .stale:
            break
        }
    }

    func syncImageConversionHotKey() {
        guard !isTerminating else {
            clipboardImageConversionHotKey?.stop()
            return
        }
        guard settings.imageConversionEnabled else {
            clipboardImageConversionHotKey?.stop()
            clipboardImageConversionOwnership.cancelPendingUtilityOperationIfNotAutomatic(
                utilityGeneration: utilityToastGeneration,
                cancel: { cancelPendingUtilityToast() }
            )
            return
        }
        guard !isScreenshotSaveAndCopyHotKeyRecording else {
            clipboardImageConversionHotKey?.stop()
            return
        }
        guard clipboardImageConversionHotKey?.start() != noErr else { return }
        settings.imageConversionEnabled = false
        presentUtilityToast(
            "Image conversion shortcut unavailable",
            style: .image,
            symbolName: "photo.badge.exclamationmark"
        )
    }

    func startImageConversion() {
        guard !isTerminating, settings.imageConversionEnabled else { return }
        performImageConversion(.manual)
    }

    func startAutomaticImageConversion(
        capturedSource: ClipboardImageConversionCapturedSource,
        outputFormat: ClipboardImageFormat
    ) {
        guard !isTerminating, settings.automaticImageConversionEnabled else { return }
        performImageConversion(.automatic(capturedSource, outputFormat: outputFormat))
    }

    private func performImageConversion(_ request: ImageConversionRequest) {
        guard let clipboardImageConversionController else { return }
        let automatically = request.isAutomatic
        let operationGeneration = beginUtilityOperation()
        if automatically {
            clipboardImageConversionOwnership.beginAutomaticConversion(generation: operationGeneration)
        }
        let mutationGeneration = beginClipboardMutation()
        let completion: (ClipboardImageConversionController.Result) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.endClipboardMutation(mutationGeneration)
                self.clipboardImageConversionOwnership.completeAutomaticConversion(
                    generation: operationGeneration
                )
            }
        }

        switch request {
        case .manual:
            clipboardImageConversionController.convertClipboardImage(completion: completion)
        case let .automatic(capturedSource, outputFormat):
            clipboardImageConversionController.convertCapturedClipboardImage(
                capturedSource,
                outputFormat: outputFormat,
                completion: completion
            )
        }
    }

    func syncMarkdownHotKey() {
        guard !isTerminating else {
            clipboardMarkdownHotKey?.stop()
            return
        }
        guard settings.markdownClipboardCleanerEnabled else {
            clipboardMarkdownHotKey?.stop()
            cancelPendingMarkdownHotKeyCleaning()
            return
        }
        guard !isScreenshotSaveAndCopyHotKeyRecording else {
            clipboardMarkdownHotKey?.stop()
            return
        }
        guard clipboardMarkdownHotKey?.start() != noErr else { return }
        settings.markdownClipboardCleanerEnabled = false
        presentUtilityToast(
            "Clean Markdown shortcut unavailable",
            style: .text,
            symbolName: "textformat",
            footer: nil,
            expectedGeneration: nil,
            interruptsPendingOperations: false
        )
    }

    private func cancelPendingMarkdownHotKeyCleaning() {
        guard activeMarkdownCleaning?.trigger == .hotKey else { return }
        activeMarkdownCleaning = nil
        clipboardMarkdownController?.cancelPendingCleaning()
        cancelActiveClipboardMutation()
    }

    func cleanMarkdownClipboard(
        trigger: MarkdownCleaningTrigger = .manual
    ) {
        guard !isTerminating else { return }
        guard let clipboardMarkdownController else { return }
        let generation = beginUtilityOperation()
        let mutationGeneration = beginClipboardMutation()
        activeMarkdownCleaning = (generation: generation, trigger: trigger)
        clipboardMarkdownController.requestCleaning { [weak self] result in
            guard let self else { return }
            self.endClipboardMutation(mutationGeneration)
            if self.activeMarkdownCleaning?.generation == generation {
                self.activeMarkdownCleaning = nil
            }
            guard self.utilityToastGeneration == generation,
                  let content = ClipboardMarkdownPresentation.toastContent(for: result) else {
                return
            }
            self.presentUtilityToast(
                content.message,
                style: .text,
                symbolName: "textformat",
                footer: content.footer,
                expectedGeneration: generation
            )
            if let acknowledgedChangeCount = content.acknowledgedChangeCount {
                self.clipboardToastController?.acknowledgeClipboardChange(acknowledgedChangeCount)
            }
        }
    }

    func presentConvertedImageToast(
        _ url: URL,
        changeCount: Int,
        enqueueEnrichment: ((
            ClipboardImageEnrichmentRequest,
            ClipboardOptionalImageEnrichmentCompletion
        ) -> Void)? = nil,
        expectedGeneration: UInt64? = nil
    ) {
        if let expectedGeneration,
           utilityToastGeneration != expectedGeneration {
            return
        }
        clipboardToastController?.dismissCurrentToast()
        let generation = beginUtilityOperation()
        let presentationToken = nextUtilityToastPresentationToken()
        let request = ClipboardImageEnrichmentRequest(
            generation: generation,
            localFileURL: url,
            typeIdentifier: ClipboardImageFormat(fileExtension: url.pathExtension)?.typeIdentifier
                ?? UTType.image.identifier
        )
        let context = ConvertedImageToastContext(
            url: url,
            changeCount: changeCount,
            generation: generation,
            request: request,
            presentationToken: presentationToken
        )
        let completion: ClipboardOptionalImageEnrichmentCompletion = { [weak self] enrichment in
            Task { @MainActor [weak self] in
                await self?.handleConvertedImageEnrichment(
                    enrichment,
                    context: context
                )
            }
        }
        if let enqueueEnrichment {
            enqueueEnrichment(request, completion)
        } else {
            clipboardUtilityImageWorker.enqueueOptional(request, completion: completion)
        }
    }

    private func handleConvertedImageEnrichment(
        _ enrichment: ClipboardImageEnrichment?,
        context: ConvertedImageToastContext
    ) async {
        let url = context.url
        let changeCount = context.changeCount
        let generation = context.generation
        let request = context.request
        let presentationToken = context.presentationToken
        guard utilityToastGeneration == generation,
              NSPasteboard.general.changeCount == changeCount,
              utilityToastPresentationToken == presentationToken else {
            return
        }
        let ownsCurrentPasteboard = await PasteboardSnapshot.exactFileURL(
            from: NSPasteboard.general,
            maximumItems: PasteboardSnapshotPolicy.maximumItems,
            maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem,
            expectedChangeCount: changeCount
        ) == url.standardizedFileURL
        guard ownsCurrentPasteboard,
              utilityToastGeneration == generation,
              NSPasteboard.general.changeCount == changeCount,
              utilityToastPresentationToken == presentationToken else {
            return
        }
        let icon = enrichment.map {
            NSImage(
                cgImage: $0.thumbnail,
                size: NSSize(width: $0.thumbnail.width, height: $0.thumbnail.height)
            )
        } ?? NSWorkspace.shared.icon(forFile: url.path)
        var model = ToastModel(
            generation: generation,
            presentationStyle: .image,
            summary: "Converted image to \(url.lastPathComponent)",
            detail: nil,
            icon: icon,
            showsImagePreview: enrichment != nil,
            footer: enrichment?.imageFooter
        )
        if enrichment != nil {
            model.onUserAction = { [weak self] in
                guard let self,
                      self.utilityToastGeneration == generation,
                      NSPasteboard.general.changeCount == changeCount else {
                    return
                }
                self.clipboardImagePreviewOpener?.open(
                    request,
                    isCurrent: { [weak self] in
                        guard let self else { return false }
                        return self.utilityToastGeneration == generation
                            && NSPasteboard.general.changeCount == changeCount
                            && self.utilityToastPresentationToken == presentationToken
                    }
                )
            }
        }
        presentGeneralToast(
            model,
            duration: settings.toastDuration,
            utilityToastPresentationToken: presentationToken
        )
    }
    @discardableResult
    func beginClipboardMutation() -> UInt64 {
        let generation = clipboardClearURLsController?.beginClipboardMutation() ?? 0
        activeClipboardMutationGeneration = generation == 0 ? nil : generation
        return generation
    }

    func endClipboardMutation(_ generation: UInt64) {
        guard activeClipboardMutationGeneration == generation else { return }
        activeClipboardMutationGeneration = nil
        clipboardClearURLsController?.endClipboardMutation(generation)
    }

    private func cancelActiveClipboardMutation() {
        guard let generation = activeClipboardMutationGeneration else { return }
        activeClipboardMutationGeneration = nil
        clipboardClearURLsController?.endClipboardMutation(generation)
    }

    func beginUtilityOperation() -> UInt64 {
        utilityToastGeneration &+= 1
        clipboardImageConversionOwnership.invalidate()
        clipboardAutoImageConversionController?.cancelPendingDetection()
        clipboardUtilityImageWorker.cancelAll()
        clipboardToastController?.cancelPendingAcknowledgment()
        clipboardToastController?.cancelPendingPayloadOperation()
        clipboardMarkdownController?.cancelPendingCleaning()
        activeMarkdownCleaning = nil
        clipboardImageConversionController?.cancelPendingConversion()
        cancelActiveClipboardMutation()
        return utilityToastGeneration
    }

    func cancelPendingUtilityToast() {
        _ = beginUtilityOperation()
    }
}
