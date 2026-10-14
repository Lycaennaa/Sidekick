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
            },
            onSavedAndCopied: { [weak self] url in
                self?.presentScreenshotSavedCopiedToast(url)
            }
        )
        screenshotSaveAndClipboardHotKey = makeScreenshotSaveAndCopyHotKey(
            settings.screenshotSaveAndCopyShortcut
        )
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

    private func presentScreenshotSavedCopiedToast(_ url: URL) {
        let model = ToastModel(
            generation: utilityToastGeneration,
            presentationStyle: .image,
            summary: "Saved and copied SDR screenshot; HDR was not preserved.",
            detail: url.lastPathComponent,
            icon: NSImage(systemSymbolName: "camera", accessibilityDescription: "Screenshot"),
            footer: nil
        )
        toastPresentationCoordinator?.presentScreenshot(model, duration: settings.toastDuration)
    }

    private func presentPixelValueCopiedToast() {
        presentUtilityToast("Copied pixel data to clipboard.", style: .image, symbolName: "eyedropper")
    }

    func startScreenshotSaveAndClipboardHotKey() {
        guard screenshotSaveAndClipboardHotKey?.start() == noErr else {
            guard restoreDefaultScreenshotSaveAndCopyHotKey() else {
                presentScreenshotShortcutUnavailableToast()
                return
            }
            return
        }
    }

    func updateScreenshotSaveAndCopyHotKey(_ shortcut: GlobalHotKey.Shortcut) -> Bool {
        guard !shortcut.conflictsWithApplicationMenuShortcut else { return false }
        guard !shortcut.hasSameChord(as: .clipboardImageConversion),
              !shortcut.hasSameChord(as: .cleanMarkdown) else {
            return false
        }
        if screenshotSaveAndClipboardHotKey?.hasShortcut(shortcut) == true {
            settings.screenshotSaveAndCopyShortcut = shortcut
            return true
        }
        let replacement = makeScreenshotSaveAndCopyHotKey(shortcut)
        guard replacement.start() == noErr else { return false }
        screenshotSaveAndClipboardHotKey?.stop()
        screenshotSaveAndClipboardHotKey = replacement
        settings.screenshotSaveAndCopyShortcut = shortcut
        return true
    }

    func setScreenshotSaveAndCopyHotKeyRecording(_ isRecording: Bool) {
        guard isScreenshotSaveAndCopyHotKeyRecording != isRecording else { return }
        isScreenshotSaveAndCopyHotKeyRecording = isRecording
        if isRecording {
            screenshotSaveAndClipboardHotKey?.stop()
            clipboardImageConversionHotKey?.stop()
            clipboardMarkdownHotKey?.stop()
            return
        }
        guard !isTerminating else { return }
        syncImageConversionHotKey()
        syncMarkdownHotKey()
        startScreenshotSaveAndClipboardHotKey()
    }

    private func restoreDefaultScreenshotSaveAndCopyHotKey() -> Bool {
        let defaultShortcut = GlobalHotKey.Shortcut.screenshotSaveAndClipboard
        guard screenshotSaveAndClipboardHotKey?.hasShortcut(defaultShortcut) != true else { return false }
        let replacement = makeScreenshotSaveAndCopyHotKey(defaultShortcut)
        guard replacement.start() == noErr else { return false }
        screenshotSaveAndClipboardHotKey?.stop()
        screenshotSaveAndClipboardHotKey = replacement
        settings.screenshotSaveAndCopyShortcut = defaultShortcut
        presentUtilityToast(
            "Screenshot shortcut became unavailable; restored ⌘⌥⇧5.",
            style: .image,
            symbolName: "camera"
        )
        return true
    }

    private func presentScreenshotShortcutUnavailableToast() {
        presentUtilityToast(
            "Screenshot shortcut unavailable; use the status menu.",
            style: .image,
            symbolName: "camera.badge.exclamationmark"
        )
    }

    private func makeScreenshotSaveAndCopyHotKey(_ shortcut: GlobalHotKey.Shortcut) -> GlobalHotKey {
        GlobalHotKey(shortcut: shortcut) { [weak self] in
            self?.captureScreenshotToClipboard(mode: .saveAndCopy)
        }
    }

    func captureScreenshotToClipboard(
        cursorOverride: Bool? = nil,
        mode: ScreenshotCaptureMode = .copy,
        windowSelection: Bool = false
    ) {
        guard !isTerminating,
              !applicationTerminationPending,
              let controller = screenshotCaptureController,
              screenshotCaptureTask == nil else { return }
        let requestID = UUID()
        screenshotCaptureRequestID = requestID
        screenshotCaptureTask = Task { @MainActor [weak self, controller] in
            if windowSelection {
                await controller.copySelectedWindowToClipboard(mode: mode)
            } else {
                await controller.copyActiveDisplayToClipboard(cursorOverride: cursorOverride, mode: mode)
            }
            guard let self, self.screenshotCaptureRequestID == requestID else { return }
            self.screenshotCaptureTask = nil
            self.screenshotCaptureRequestID = nil
        }
    }

    private func handleScreenshotCaptureFailure(_ failure: ScreenshotCaptureController.Failure) {
        let message = ScreenshotCaptureFailurePresentation.message(
            for: failure,
            screenRecordingAllowed: { CGPreflightScreenCaptureAccess() }
        )
        presentUtilityToast(
            message,
            style: .image,
            symbolName: "camera.badge.exclamationmark"
        )
    }
}
