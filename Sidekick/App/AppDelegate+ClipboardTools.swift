import AppKit
import UniformTypeIdentifiers

private struct ConvertedImageToastContext {
    let url: URL
    let changeCount: Int
    let generation: UInt64
    let request: ClipboardImageEnrichmentRequest
    let presentationToken: UInt64
    let copyContext: ConvertedImageToastCopyContext
    let clipboardToastGenerationToReplace: UInt64?
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
    func convertedImageToastCopyContext(
        sourceChangeCount: Int,
        automaticGenerationMatches: Bool
    ) -> ConvertedImageToastCopyContext? {
        guard automaticGenerationMatches else { return .converted }
        guard screenshotClipboardMetadataRegistry.isScreenshot(forChangeCount: sourceChangeCount) else {
            return .clipboardImage(sourceChangeCount: sourceChangeCount)
        }
        guard let screenshotCopyToastContext,
              screenshotCopyToastContext.sourceChangeCount == sourceChangeCount else {
            return .converted
        }
        return screenshotCopyToastContext.convertedToastCopyContext(
            ifCurrent: self.screenshotCopyToastContext
        )
    }

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
        capture: ClipboardImageConversionCapture,
        outputFormat: ClipboardImageFormat
    ) {
        guard !isTerminating, settings.automaticImageConversionEnabled else { return }
        switch capture {
        case let .source(capturedSource):
            performImageConversion(.automatic(capturedSource, outputFormat: outputFormat))
        case .unavailable, .failed:
            clipboardImageConversionController?.reportCaptureFailure(capture)
        case .alreadyOutputFormat, .noImage, .stale:
            break
        }
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
        copyContext: ConvertedImageToastCopyContext,
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
        let clipboardToastGenerationToReplace: UInt64?
        if case let .clipboardImage(sourceChangeCount) = copyContext {
            clipboardToastGenerationToReplace = clipboardToastController?.prepareCurrentToastReplacement(
                forChangeCount: sourceChangeCount
            )
        } else {
            clipboardToastGenerationToReplace = nil
        }
        if clipboardToastGenerationToReplace == nil {
            clipboardToastController?.dismissCurrentToast()
        }
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
            presentationToken: presentationToken,
            copyContext: copyContext,
            clipboardToastGenerationToReplace: clipboardToastGenerationToReplace
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
        guard let copyContext = currentConvertedImageToastCopyContext(for: context) else { return }
        let icon = enrichment.map {
            NSImage(
                cgImage: $0.thumbnail,
                size: NSSize(width: $0.thumbnail.width, height: $0.thumbnail.height)
            )
        } ?? NSWorkspace.shared.icon(forFile: url.path)
        let model = makeConvertedImageToastModel(
            context: context,
            copyContext: copyContext,
            enrichment: enrichment,
            icon: icon
        )
        if copyContext.isScreenshot {
            toastPresentationCoordinator?.presentScreenshot(
                model,
                duration: settings.toastDuration
            )
            if case let .screenshot(screenshotCopyToastContext) = copyContext,
               self.screenshotCopyToastContext == screenshotCopyToastContext {
                self.screenshotCopyToastContext = nil
            }
        } else {
            presentGeneralToast(
                model,
                duration: settings.toastDuration,
                utilityToastPresentationToken: presentationToken
            )
        }
        if let clipboardToastGenerationToReplace = context.clipboardToastGenerationToReplace {
            clipboardToastController?.toastDidDismiss(generation: clipboardToastGenerationToReplace)
        }
    }

    private func currentConvertedImageToastCopyContext(
        for context: ConvertedImageToastContext
    ) -> ConvertedImageToastCopyContext? {
        switch context.copyContext {
        case let .clipboardImage(sourceChangeCount):
            if let sourceToastGeneration = context.clipboardToastGenerationToReplace,
               clipboardToastController?.hasCurrentToast(generation: sourceToastGeneration) == true {
                return .clipboardImage(sourceChangeCount: sourceChangeCount)
            }
            return .converted
        case let .screenshot(screenshotCopyToastContext):
            return screenshotCopyToastContext.convertedToastCopyContext(
                ifCurrent: self.screenshotCopyToastContext
            )
        case .converted:
            return .converted
        }
    }

    private func makeConvertedImageToastModel(
        context: ConvertedImageToastContext,
        copyContext: ConvertedImageToastCopyContext,
        enrichment: ClipboardImageEnrichment?,
        icon: NSImage
    ) -> ToastModel {
        var model = ConvertedImageToastPresentation.model(
            url: context.url,
            generation: context.generation,
            copyContext: copyContext,
            icon: icon,
            enrichment: enrichment
        )
        guard enrichment != nil else { return model }
        model.onUserAction = { [weak self] in
            guard let self,
                  self.utilityToastGeneration == context.generation,
                  NSPasteboard.general.changeCount == context.changeCount else {
                return
            }
            self.clipboardImagePreviewOpener?.open(
                context.request,
                isCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.utilityToastGeneration == context.generation
                        && NSPasteboard.general.changeCount == context.changeCount
                        && self.utilityToastPresentationToken == context.presentationToken
                }
            )
        }
        return model
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

    func beginUtilityOperation(
        detectionCancellationReason:
            ClipboardAutoImageConversionController.DetectionCancellationReason = .utilityOperation
    ) -> UInt64 {
        utilityToastGeneration &+= 1
        clipboardImageConversionOwnership.invalidate()
        clipboardAutoImageConversionController?.cancelPendingDetection(
            reason: detectionCancellationReason
        )
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
        clipboardImageConversionOwnership.cancelPendingUtilityOperationIfNotAutomatic(
            utilityGeneration: utilityToastGeneration
        ) {
            _ = beginUtilityOperation(detectionCancellationReason: .clipboardToast)
        }
    }
}
