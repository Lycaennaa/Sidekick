import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotSelectionResult {
    case selected(CGImage)
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
}

@MainActor
final class ScreenshotCaptureController {
    enum Failure: Equatable {
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
    }
    private enum ClipboardReplacement {
        case installed(changeCount: Int)
        case cancelled
        case failed(Failure)
        case failedButRestored(changeCount: Int)
    }

    @MainActor
    private final class RequestState {
        let id: UUID
        var expectedChangeCount: Int

        init(id: UUID, expectedChangeCount: Int) {
            self.id = id
            self.expectedChangeCount = expectedChangeCount
        }
    }

    private enum SnapshotCapture {
        case captured(PasteboardSnapshot)
        case cancelled
        case failed(Failure)
    }

    private struct SelectedClipboardItem {
        let item: NSPasteboardItem
        let isScreenshot: Bool
    }

    typealias Capture = @MainActor (Bool) async throws -> CapturedDisplayScreenshot
    typealias WindowCapture = ScreenshotWindowCapture
    typealias Select = @MainActor (
        CapturedDisplayScreenshot,
        Bool,
        WindowCapture,
        ScreenshotPixelValueCopy
    ) async -> ScreenshotSelectionResult

    private static let snapshotLimits = PasteboardSnapshot.Limits(
        maximumBytes: PasteboardSnapshotPolicy.maximumBytes,
        maximumItems: PasteboardSnapshotPolicy.maximumItems,
        maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem
    )

    private let settings: AppSettings
    private let pasteboard: any PasteboardAccess
    private let capture: Capture
    private let captureWindow: WindowCapture
    private let select: Select
    private let payloadReader: any PasteboardPayloadReading
    private let metadataRegistry: ScreenshotClipboardMetadataRegistry
    private let onCopied: () -> Void
    private let onPixelValueCopied: () -> Void
    private let onFailure: (Failure) -> Void
    private var activeRequestID: UUID?
    private var mutationRequestID: UUID?

    var hasPendingPasteboardMutation: Bool {
        mutationRequestID != nil
    }

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
        onFailure: @escaping (Failure) -> Void
    ) {
        self.pasteboard = pasteboard
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
        self.metadataRegistry = metadataRegistry
        self.payloadReader = payloadReader
        self.onCopied = onCopied
        self.onPixelValueCopied = onPixelValueCopied
        self.onFailure = onFailure
    }

    func copyActiveDisplayToClipboard(cursorOverride: Bool? = nil) async {
        guard activeRequestID == nil else { return }
        let showsCursor = cursorOverride ?? settings.screenshotCursorIncludedByDefault
        let request = RequestState(id: UUID(), expectedChangeCount: pasteboard.changeCount)
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
        guard let selection = makeClipboardItem(from: result) else { return }
        await installClipboardItem(selection, request: request)
    }

    private func makeClipboardItem(from result: ScreenshotSelectionResult) -> SelectedClipboardItem? {
        switch result {
        case let .selected(image):
            guard let item = makePNGClipboardItem(from: image) else {
                failSelection(with: .encoding)
                return nil
            }
            return SelectedClipboardItem(item: item, isScreenshot: true)
        case let .copiedPixelValue(value):
            let item = NSPasteboardItem()
            guard item.setString(value, forType: .string) else {
                failSelection(with: .encoding)
                return nil
            }
            return SelectedClipboardItem(item: item, isScreenshot: false)
        case .cancelled:
            activeRequestID = nil
            return nil
        case .displayUnavailable:
            failSelection(with: .selectionDisplayUnavailable)
            return nil
        case .cropFailed:
            failSelection(with: .selectionCropFailed)
            return nil
        case .windowUnavailable:
            failSelection(with: .selectionWindowUnavailable)
            return nil
        case .windowCaptureFailed:
            failSelection(with: .windowCapture)
            return nil
        }
    }

    private func failSelection(with failure: Failure) {
        activeRequestID = nil
        onFailure(failure)
    }

    private func installClipboardItem(_ selection: SelectedClipboardItem, request: RequestState) async {
        let replacement = await replaceClipboardContents(
            with: [selection.item],
            requestID: request.id,
            expectedChangeCount: request.expectedChangeCount,
            isScreenshot: selection.isScreenshot
        )
        guard activeRequestID == request.id else { return }
        guard !Task.isCancelled else {
            activeRequestID = nil
            return
        }
        switch replacement {
        case let .installed(changeCount):
            guard pasteboard.changeCount == changeCount else {
                activeRequestID = nil
                onFailure(.clipboardChanged)
                return
            }
            activeRequestID = nil
            if selection.isScreenshot {
                onCopied()
            } else {
                onPixelValueCopied()
            }
        case .cancelled:
            activeRequestID = nil
        case let .failed(failure):
            activeRequestID = nil
            onFailure(failure)
        case .failedButRestored:
            activeRequestID = nil
            onFailure(.clipboard)
        }
    }

    private func copyPixelValue(_ value: String, request: RequestState) async -> Bool {
        guard activeRequestID == request.id, !Task.isCancelled else { return false }
        guard pasteboard.changeCount == request.expectedChangeCount else {
            onFailure(.clipboardChanged)
            return false
        }
        let item = NSPasteboardItem()
        guard item.setString(value, forType: .string) else {
            onFailure(.encoding)
            return false
        }
        let replacement = await replaceClipboardContents(
            with: [item],
            requestID: request.id,
            expectedChangeCount: request.expectedChangeCount,
            isScreenshot: false
        )
        guard activeRequestID == request.id, !Task.isCancelled else { return false }
        return finishPixelValueCopy(replacement, request: request)
    }

    private func finishPixelValueCopy(
        _ replacement: ClipboardReplacement,
        request: RequestState
    ) -> Bool {
        switch replacement {
        case let .installed(changeCount):
            guard pasteboard.changeCount == changeCount else {
                onFailure(.clipboardChanged)
                return false
            }
            request.expectedChangeCount = changeCount
            onPixelValueCopied()
            return true
        case .cancelled:
            return false
        case let .failed(failure):
            onFailure(failure)
            return false
        case let .failedButRestored(changeCount):
            guard pasteboard.changeCount == changeCount else {
                onFailure(.clipboardChanged)
                return false
            }
            request.expectedChangeCount = changeCount
            onFailure(.clipboard)
            return false
        }
    }

    private func replaceClipboardContents(
        with items: [NSPasteboardWriting],
        requestID: UUID,
        expectedChangeCount: Int,
        isScreenshot: Bool
    ) async -> ClipboardReplacement {
        let snapshotCapture = await captureSnapshot(
            requestID: requestID,
            expectedChangeCount: expectedChangeCount
        )
        let snapshot: PasteboardSnapshot
        switch snapshotCapture {
        case let .captured(value):
            snapshot = value
        case .cancelled:
            return .cancelled
        case let .failed(failure):
            return .failed(failure)
        }
        guard activeRequestID == requestID,
              !Task.isCancelled,
              pasteboard.changeCount == expectedChangeCount else {
            return .failed(.clipboardChanged)
        }
        let isCurrentRequest: @MainActor () async -> Bool = { [weak self] in
            self?.activeRequestID == requestID && !Task.isCancelled
        }
        let result = await snapshot.replace(
            pasteboard: pasteboard,
            expectedChangeCount: expectedChangeCount,
            with: items,
            maximumBytes: Self.snapshotLimits.maximumBytes,
            maximumTypesPerItem: Self.snapshotLimits.maximumTypesPerItem,
            payloadReader: payloadReader,
            isStillOwned: isCurrentRequest,
            onMutation: { [weak self, metadataRegistry] changeCount in
                self?.mutationRequestID = requestID
                if isScreenshot {
                    metadataRegistry.register(.sdr, forChangeCount: changeCount)
                }
            },
            verify: isCurrentRequest
        )
        if mutationRequestID == requestID {
            mutationRequestID = nil
        }
        guard activeRequestID == requestID else { return .cancelled }
        guard !Task.isCancelled else { return .cancelled }
        return clipboardReplacement(from: result)
    }

    func terminate() {
        activeRequestID = nil
    }

    private func makePNGClipboardItem(from image: CGImage) -> NSPasteboardItem? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let item = NSPasteboardItem()
        guard item.setData(data as Data, forType: .png) else { return nil }
        return item
    }
}
private extension ScreenshotCaptureController {
    private func captureSnapshot(
        requestID: UUID,
        expectedChangeCount: Int
    ) async -> SnapshotCapture {
        guard activeRequestID == requestID, !Task.isCancelled else { return .cancelled }
        guard pasteboard.changeCount == expectedChangeCount else {
            return .failed(.clipboardChanged)
        }
        let result = await PasteboardSnapshot.capture(
            from: pasteboard,
            expectedChangeCount: expectedChangeCount,
            limits: Self.snapshotLimits,
            payloadReader: payloadReader
        )
        guard activeRequestID == requestID else { return .cancelled }
        guard !Task.isCancelled else { return .cancelled }
        guard pasteboard.changeCount == expectedChangeCount else {
            return .failed(.clipboardChanged)
        }
        switch result {
        case let .captured(snapshot):
            return .captured(snapshot)
        case .stale:
            return .failed(.clipboardChanged)
        case .failed:
            return .failed(.clipboardSnapshot)
        }
    }

    private func clipboardReplacement(
        from result: PasteboardSnapshot.ReplacementResult
    ) -> ClipboardReplacement {
        switch result {
        case let .installed(changeCount):
            guard pasteboard.changeCount == changeCount else {
                return .failed(.clipboardChanged)
            }
            return .installed(changeCount: changeCount)
        case .stale:
            return .failed(.clipboardChanged)
        case let .failed(restoredChangeCount):
            guard pasteboard.changeCount == restoredChangeCount else {
                return .failed(.clipboardChanged)
            }
            return .failedButRestored(changeCount: restoredChangeCount)
        case .restoreFailed:
            return .failed(.clipboardRestore)
        }
    }
}
