import AppKit
import CoreGraphics

enum ScreenshotCaptureMode: Sendable, Equatable {
    case copy
    case saveAndCopy
}

enum ScreenshotSelectionResult {
    case selected(CGImage)
    case copyOnly(CGImage)
    case saveAndCopy(CGImage, windowTitle: String?)
    case selectedWindow(CGImage, windowTitle: String?)
    case copiedPixelValue(String)
    case cancelled
    case displayUnavailable
    case cropFailed
    case windowUnavailable
    case windowCaptureFailed
}

typealias ScreenshotPixelValueCopy = @MainActor (String) async -> Bool

enum ScreenshotCaptureFailurePresentation {
    static func permissionAwareCaptureMessage(
        screenRecordingAllowed: Bool,
        isWindowCapture: Bool = false
    ) -> String {
        guard screenRecordingAllowed else {
            return "Allow Screen Recording for Sidekick in System Settings, then retry."
        }
        if isWindowCapture {
            return "Couldn’t capture the selected window; choose another window or region."
        }
        return "Couldn’t capture the display."
    }
    private static let failureMessages: [ScreenshotCaptureController.Failure: String] = [
        .clipboard: "Couldn’t copy the selected content; your previous clipboard was restored.",
        .clipboardChanged: "Clipboard changed during capture; newer clipboard contents were kept.",
        .clipboardSnapshot: "Couldn’t safely preserve the existing clipboard; it was not replaced.",
        .clipboardRestore: "Copy failed and the previous clipboard could not be restored.",
        .encoding: "Couldn’t prepare the selected content for the clipboard.",
        .selectionDisplayUnavailable: "The captured display changed before selection; retry the screenshot.",
        .selectionCropFailed: "Couldn’t create the selected screenshot; try again.",
        .selectionWindowUnavailable:
            "That window is fully hidden or unavailable; choose an exposed portion or drag a region.",
        .save: "Couldn’t save screenshot. Check that the configured folder is available.",
        .savedButNotCopied: "Screenshot saved, but it could not be copied to the clipboard.",
        .savedButClipboardChanged: "Screenshot saved, but clipboard changed; newer clipboard contents were kept.",
        .savedButClipboardRestoreFailed:
            "Screenshot saved, but the previous clipboard could not be restored."
    ]

    static func message(
        for failure: ScreenshotCaptureController.Failure,
        screenRecordingAllowed: () -> Bool
    ) -> String {
        switch failure {
        case .capture:
            return permissionAwareCaptureMessage(screenRecordingAllowed: screenRecordingAllowed())
        case .windowCapture:
            return permissionAwareCaptureMessage(
                screenRecordingAllowed: screenRecordingAllowed(),
                isWindowCapture: true
            )
        default:
            return failureMessages[failure] ?? "Couldn’t complete the screenshot operation."
        }
    }
}

enum SelectedClipboardItemContent {
    case screenshot(Data, String?, ScreenshotCaptureMode)
    case pixelValue
}

@MainActor
final class ScreenshotCaptureController {
    enum Failure: Hashable {
        case capture
        case windowCapture
        case clipboard
        case clipboardChanged
        case clipboardSnapshot
        case clipboardRestore
        case encoding
        case selectionDisplayUnavailable
        case selectionCropFailed
        case selectionWindowUnavailable
        case save
        case savedButNotCopied
        case savedButClipboardChanged
        case savedButClipboardRestoreFailed
    }

    final class RequestState {
        let id: UUID
        let delivery: ScreenshotCaptureMode
        let startedAt: Date
        let saveDirectory: URL
        let filenameTemplate: String
        var expectedChangeCount: Int
        var savedURL: URL?

        init(
            id: UUID,
            expectedChangeCount: Int,
            delivery: ScreenshotCaptureMode,
            startedAt: Date,
            saveDirectory: URL,
            filenameTemplate: String
        ) {
            self.id = id
            self.expectedChangeCount = expectedChangeCount
            self.delivery = delivery
            self.startedAt = startedAt
            self.saveDirectory = saveDirectory
            self.filenameTemplate = filenameTemplate
        }
    }

    struct SelectedClipboardItem {
        let item: NSPasteboardItem
        let content: SelectedClipboardItemContent

        var isScreenshot: Bool {
            switch content {
            case .screenshot:
                return true
            case .pixelValue:
                return false
            }
        }
    }

    typealias Capture = @MainActor (Bool) async throws -> CapturedDisplayScreenshot
    typealias WindowCapture = ScreenshotWindowCapture
    typealias Select = @MainActor (
        CapturedDisplayScreenshot,
        Bool,
        WindowCapture,
        ScreenshotPixelValueCopy
    ) async -> ScreenshotSelectionResult
    typealias SavePreparation = @MainActor (Data, URL, String) async throws -> ScreenshotSaveService.Prepared

    private let settings: AppSettings
    private let capture: Capture
    private let captureWindow: WindowCapture
    private let select: Select
    let clipboardWriter: ScreenshotClipboardWriter
    let onCopied: () -> Void
    let onPixelValueCopied: () -> Void
    let onFailure: (Failure) -> Void
    let onSavedAndCopied: (URL) -> Void
    private let prepareSave: SavePreparation
    var activeRequestID: UUID?
    private var pendingSaveRequestID: UUID?

    var hasPendingPasteboardMutation: Bool { clipboardWriter.hasPendingMutation }
    var hasPendingSavePreparation: Bool { pendingSaveRequestID != nil }

    init(
        pasteboard: any PasteboardAccess = NSPasteboard.general,
        settings: AppSettings = AppSettings(),
        capture: @escaping Capture = { showsCursor in
            try await ActiveDisplayScreenshotCapture.capture(showsCursor: showsCursor)
        },
        captureWindow: @escaping WindowCapture = { target, showsCursor in
            try await ActiveDisplayScreenshotCapture.captureWindow(target, showsCursor: showsCursor)
        },
        select: Select? = nil,
        metadataRegistry: ScreenshotClipboardMetadataRegistry = ScreenshotClipboardMetadataRegistry(),
        payloadReader: any PasteboardPayloadReading = SystemPasteboardPayloadReader(),
        onCopied: @escaping () -> Void,
        onPixelValueCopied: @escaping () -> Void = {},
        onFailure: @escaping (Failure) -> Void,
        onSavedAndCopied: @escaping (URL) -> Void = { _ in },
        prepareSave: SavePreparation? = nil
    ) {
        self.clipboardWriter = ScreenshotClipboardWriter(
            pasteboard: pasteboard,
            metadataRegistry: metadataRegistry,
            payloadReader: payloadReader
        )
        self.settings = settings
        self.capture = capture
        self.captureWindow = captureWindow
        self.select = select ?? { screenshot, showsCursor, windowCapture, copyPixelValues in
            await ScreenshotSelectionOverlay.select(
                screenshot,
                showsCursor: showsCursor,
                captureWindow: windowCapture,
                copyPixelValues: copyPixelValues
            )
        }
        self.onCopied = onCopied
        self.onPixelValueCopied = onPixelValueCopied
        self.onFailure = onFailure
        self.onSavedAndCopied = onSavedAndCopied
        self.prepareSave = prepareSave ?? { pngData, directory, baseName in
            try await ScreenshotSaveService.prepareInBackground(
                pngData: pngData,
                directory: directory,
                baseName: baseName
            )
        }
    }

    func copyActiveDisplayToClipboard(
        cursorOverride: Bool? = nil,
        mode: ScreenshotCaptureMode = .copy
    ) async {
        guard activeRequestID == nil else { return }
        let showsCursor = cursorOverride ?? settings.screenshotCursorIncludedByDefault
        let request = RequestState(
            id: UUID(),
            expectedChangeCount: clipboardWriter.changeCount,
            delivery: mode,
            startedAt: Date(),
            saveDirectory: settings.screenshotSaveDirectoryURL,
            filenameTemplate: settings.screenshotFilenameTemplate
        )
        activeRequestID = request.id
        guard let screenshot = await captureScreenshot(
            showsCursor: showsCursor,
            requestID: request.id
        ) else {
            return
        }
        await selectAndCopy(screenshot, showsCursor: showsCursor, request: request)
    }

    private func captureScreenshot(
        showsCursor: Bool,
        requestID: UUID
    ) async -> CapturedDisplayScreenshot? {
        do {
            let screenshot = try await capture(showsCursor)
            guard activeRequestID == requestID else { return nil }
            guard !Task.isCancelled else {
                activeRequestID = nil
                return nil
            }
            return screenshot
        } catch {
            guard activeRequestID == requestID else { return nil }
            guard !Task.isCancelled else {
                activeRequestID = nil
                return nil
            }
            activeRequestID = nil
            onFailure(.capture)
            return nil
        }
    }

    private func selectAndCopy(
        _ screenshot: CapturedDisplayScreenshot,
        showsCursor: Bool,
        request: RequestState
    ) async {
        let result = await select(screenshot, showsCursor, captureWindow) { [weak self] value in
            guard let self else { return false }
            return await self.copyPixelValue(value, request: request)
        }
        guard activeRequestID == request.id else { return }
        guard !Task.isCancelled else {
            activeRequestID = nil
            return
        }
        guard let selection = makeClipboardItem(from: result, delivery: request.delivery) else { return }
        if case let .screenshot(pngData, windowTitle, .saveAndCopy) = selection.content {
            guard await saveSelectedScreenshot(
                pngData,
                windowTitle: windowTitle,
                request: request
            ) else { return }
            guard activeRequestID == request.id else { return }
            guard !Task.isCancelled else {
                activeRequestID = nil
                return
            }
            guard clipboardWriter.changeCount == request.expectedChangeCount else {
                activeRequestID = nil
                onFailure(.savedButClipboardChanged)
                return
            }
        }
        await installClipboardItem(selection, request: request)
    }

    private func saveSelectedScreenshot(
        _ pngData: Data,
        windowTitle: String?,
        request: RequestState
    ) async -> Bool {
        guard activeRequestID == request.id else { return false }
        guard !Task.isCancelled else {
            activeRequestID = nil
            return false
        }
        guard clipboardWriter.changeCount == request.expectedChangeCount else {
            failSelection(with: .clipboardChanged)
            return false
        }
        let baseName = ScreenshotFilenameTemplate.baseName(
            template: request.filenameTemplate,
            date: request.startedAt,
            windowTitle: windowTitle
        )
        pendingSaveRequestID = request.id
        do {
            let prepared = try await prepareSave(pngData, request.saveDirectory, baseName)
            return publishPreparedScreenshot(prepared, request: request)
        } catch {
            return finishFailedScreenshotPreparation(for: request)
        }
    }

    private func finishFailedScreenshotPreparation(for request: RequestState) -> Bool {
        guard pendingSaveRequestID == request.id else { return false }
        pendingSaveRequestID = nil
        guard activeRequestID == request.id else { return false }
        guard !Task.isCancelled else {
            activeRequestID = nil
            return false
        }
        guard clipboardWriter.changeCount == request.expectedChangeCount else {
            failSelection(with: .clipboardChanged)
            return false
        }
        failSelection(with: .save)
        return false
    }

    private func publishPreparedScreenshot(
        _ prepared: ScreenshotSaveService.Prepared,
        request: RequestState
    ) -> Bool {
        guard pendingSaveRequestID == request.id else {
            ScreenshotSaveService.discard(prepared)
            return false
        }
        guard activeRequestID == request.id,
              !Task.isCancelled,
              clipboardWriter.changeCount == request.expectedChangeCount else {
            ScreenshotSaveService.discard(prepared)
            pendingSaveRequestID = nil
            guard activeRequestID == request.id else { return false }
            guard !Task.isCancelled else {
                activeRequestID = nil
                return false
            }
            failSelection(with: .clipboardChanged)
            return false
        }
        pendingSaveRequestID = nil
        do {
            request.savedURL = try ScreenshotSaveService.commit(prepared)
            return true
        } catch {
            ScreenshotSaveService.discard(prepared)
            failSelection(with: .save)
            return false
        }
    }

    func terminate() {
        activeRequestID = nil
    }

}
