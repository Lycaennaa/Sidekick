import AppKit
import UniformTypeIdentifiers

extension ScreenshotCaptureController {
    func installClipboardItem(_ selection: SelectedClipboardItem, request: RequestState) async {
        let result = await clipboardWriter.replace(
            with: selection.item,
            isScreenshot: selection.isScreenshot,
            expectedChangeCount: request.expectedChangeCount,
            isCurrentRequest: { [weak self] in self?.activeRequestID == request.id }
        )
        guard activeRequestID == request.id else { return }
        guard !Task.isCancelled else {
            activeRequestID = nil
            return
        }
        switch result {
        case let .installed(changeCount):
            guard clipboardWriter.changeCount == changeCount else {
                activeRequestID = nil
                onFailure(request.savedURL == nil ? .clipboardChanged : .savedButClipboardChanged)
                return
            }
            activeRequestID = nil
            reportClipboardItemInstalled(selection, savedURL: request.savedURL)
        case .cancelled:
            activeRequestID = nil
        case let .failed(failure):
            activeRequestID = nil
            let captureFailure = captureFailure(for: failure)
            guard request.savedURL != nil else {
                onFailure(captureFailure)
                return
            }
            onFailure(savedScreenshotFailure(for: captureFailure))
        case .failedButRestored:
            activeRequestID = nil
            onFailure(request.savedURL == nil ? .clipboard : .savedButNotCopied)
        }
    }

    func prepareClipboardItemForCopy(
        _ selection: SelectedClipboardItem,
        copyAsOutputFormat: Bool,
        imageFormat: ClipboardImageFormat,
        preparedOutputFormatData: Data?
    ) async throws -> SelectedClipboardItem {
        guard copyAsOutputFormat,
              case let .screenshot(pngData, _) = selection.content else {
            return selection
        }

        let outputData: Data
        if let preparedOutputFormatData {
            outputData = preparedOutputFormatData
        } else {
            outputData = try await prepareClipboardImage(pngData, imageFormat)
        }
        let item = NSPasteboardItem()
        guard item.setData(outputData, forType: NSPasteboard.PasteboardType(imageFormat.typeIdentifier)) else {
            throw ClipboardImageConversionError.cannotEncode
        }
        return SelectedClipboardItem(item: item, content: selection.content)
    }

    private func reportClipboardItemInstalled(_ selection: SelectedClipboardItem, savedURL: URL?) {
        switch selection.content {
        case .screenshot:
            if let savedURL {
                onSavedAndCopied(savedURL)
            } else {
                onCopied()
            }
        case .pixelValue:
            onPixelValueCopied()
        }
    }

    private func savedScreenshotFailure(for failure: Failure) -> Failure {
        switch failure {
        case .clipboardChanged:
            return .savedButClipboardChanged
        case .clipboardRestore:
            return .savedButClipboardRestoreFailed
        default:
            return .savedButNotCopied
        }
    }

    func copyPixelValue(_ value: String, request: RequestState) async -> Bool {
        guard activeRequestID == request.id, !Task.isCancelled else { return false }
        guard clipboardWriter.changeCount == request.expectedChangeCount else {
            failSelection(with: .clipboardChanged)
            return false
        }
        let item = NSPasteboardItem()
        guard item.setString(value, forType: .string) else {
            onFailure(.encoding)
            return false
        }
        let result = await clipboardWriter.replace(
            with: item,
            isScreenshot: false,
            expectedChangeCount: request.expectedChangeCount,
            isCurrentRequest: { [weak self] in self?.activeRequestID == request.id }
        )
        guard activeRequestID == request.id, !Task.isCancelled else { return false }
        return finishPixelValueCopy(result, request: request)
    }

    private func finishPixelValueCopy(
        _ result: ScreenshotClipboardWriter.Result,
        request: RequestState
    ) -> Bool {
        switch result {
        case let .installed(changeCount):
            guard clipboardWriter.changeCount == changeCount else {
                failSelection(with: .clipboardChanged)
                return false
            }
            request.expectedChangeCount = changeCount
            onPixelValueCopied()
            return true
        case .cancelled:
            return false
        case let .failed(failure):
            if case .changed = failure {
                failSelection(with: .clipboardChanged)
            } else {
                onFailure(captureFailure(for: failure))
            }
            return false
        case let .failedButRestored(changeCount):
            guard clipboardWriter.changeCount == changeCount else {
                failSelection(with: .clipboardChanged)
                return false
            }
            request.expectedChangeCount = changeCount
            onFailure(.clipboard)
            return false
        }
    }

    private func captureFailure(for failure: ScreenshotClipboardWriter.Failure) -> Failure {
        switch failure {
        case .changed:
            return .clipboardChanged
        case .snapshot:
            return .clipboardSnapshot
        case .restore:
            return .clipboardRestore
        }
    }
}

extension ScreenshotCaptureController {
    func makeScreenshotItem(
        from image: CGImage,
        delivery: ScreenshotCaptureMode
    ) -> SelectedClipboardItem? {
        guard let pngData = ScreenshotPNGEncoder.encode(image) else {
            failSelection(with: .encoding)
            return nil
        }
        let item = NSPasteboardItem()
        guard item.setData(pngData, forType: .png) else {
            failSelection(with: .encoding)
            return nil
        }
        return SelectedClipboardItem(
            item: item,
            content: .screenshot(pngData, delivery)
        )
    }

    func failSelection(with failure: Failure) {
        activeRequestID = nil
        onFailure(failure)
    }

    func makeClipboardItem(
        from result: ScreenshotSelectionResult,
        delivery: ScreenshotCaptureMode
    ) -> SelectedClipboardItem? {
        switch result {
        case let .copyOnly(image):
            return makeScreenshotItem(from: image, delivery: .copy)
        case let .saveAndCopy(image):
            return makeScreenshotItem(from: image, delivery: .saveAndCopy)
        case let .selected(image):
            return makeScreenshotItem(from: image, delivery: delivery)
        case let .copiedPixelValue(value):
            let item = NSPasteboardItem()
            guard item.setString(value, forType: .string) else {
                failSelection(with: .encoding)
                return nil
            }
            return SelectedClipboardItem(item: item, content: .pixelValue)
        case .windowCapture:
            return nil
        case .cancelled:
            activeRequestID = nil
            return nil
        case .displayUnavailable, .cropFailed:
            guard let failure = selectionFailure(for: result) else { return nil }
            failSelection(with: failure)
            return nil
        }
    }

    private func selectionFailure(for result: ScreenshotSelectionResult) -> Failure? {
        switch result {
        case .displayUnavailable:
            return .selectionDisplayUnavailable
        case .cropFailed:
            return .selectionCropFailed
        default:
            return nil
        }
    }
}
