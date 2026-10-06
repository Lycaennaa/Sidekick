import AppKit
import CoreGraphics

extension AppDelegate {
    func installScreenshotCapture() {
        screenshotCaptureController = ScreenshotCaptureController(
            settings: settings,
            metadataRegistry: screenshotClipboardMetadataRegistry,
            onCopied: { [weak self] in
                self?.presentScreenshotCopiedToast()
            },
            onPixelValueCopied: { [weak self] in
                self?.presentPixelValueCopiedToast()
            },
            onFailure: { [weak self] failure in
                self?.handleScreenshotCaptureFailure(failure)
            }
        )
        screenshotClipboardHotKey = GlobalHotKey(shortcut: .screenshotClipboard) { [weak self] in
            self?.captureScreenshotToClipboard()
        }
    }
    private func presentScreenshotCopiedToast() {
        let model = ToastModel(
            generation: utilityToastGeneration,
            presentationStyle: .image,
            summary: "Copied SDR screenshot; HDR was not preserved.",
            detail: nil,
            icon: NSImage(systemSymbolName: "camera", accessibilityDescription: "Screenshot"),
            footer: nil
        )
        toastPresentationCoordinator?.presentScreenshot(
            model,
            duration: settings.toastDuration
        )
    }

    private func presentPixelValueCopiedToast() {
        presentUtilityToast("Copied pixel data to clipboard.", style: .image, symbolName: "eyedropper")
    }

    func startScreenshotClipboardHotKey() {
        guard screenshotClipboardHotKey?.start() == noErr else {
            presentUtilityToast(
                "Screenshot shortcut unavailable; use the status menu.",
                style: .image,
                symbolName: "camera.badge.exclamationmark"
            )
            return
        }
    }

    func captureScreenshotToClipboard(cursorOverride: Bool? = nil) {
        guard let controller = screenshotCaptureController,
              screenshotCaptureTask == nil else { return }
        let requestID = UUID()
        screenshotCaptureRequestID = requestID
        screenshotCaptureTask = Task { @MainActor [weak self, controller] in
            await controller.copyActiveDisplayToClipboard(cursorOverride: cursorOverride)
            guard let self, self.screenshotCaptureRequestID == requestID else { return }
            self.screenshotCaptureTask = nil
            self.screenshotCaptureRequestID = nil
        }
    }

    private func handleScreenshotCaptureFailure(_ failure: ScreenshotCaptureController.Failure) {
        let message: String
        switch failure {
        case .capture:
            message = ScreenshotCaptureFailurePresentation.permissionAwareCaptureMessage(
                screenRecordingAllowed: CGPreflightScreenCaptureAccess()
            )
        case .windowCapture:
            message = ScreenshotCaptureFailurePresentation.permissionAwareCaptureMessage(
                screenRecordingAllowed: CGPreflightScreenCaptureAccess(),
                isWindowCapture: true
            )
        case .selectionDisplayUnavailable:
            message = "The captured display changed before selection; retry the screenshot."
        case .selectionCropFailed:
            message = "Couldn’t create the selected screenshot; try again."
        case .selectionWindowUnavailable:
            message = "That window is fully hidden or unavailable; choose an exposed portion or drag a region."
        case .clipboardSnapshot:
            message = "Couldn’t safely preserve the existing clipboard; it was not replaced."
        case .clipboardRestore:
            message = "Copy failed and the previous clipboard could not be restored."
        case .encoding:
            message = "Couldn’t prepare the selected content for the clipboard."
        case .clipboard:
            message = "Couldn’t copy the selected content; your previous clipboard was restored."
        case .clipboardChanged:
            message = "Clipboard changed during capture; newer clipboard contents were kept."
        }
        presentUtilityToast(
            message,
            style: .image,
            symbolName: "camera.badge.exclamationmark"
        )
    }
}
