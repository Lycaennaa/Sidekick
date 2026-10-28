import AppKit

extension AppDelegate {
    func showTools() {
        guard let twitchNotificationController else { return }
        guard let statusMenuController,
              let temporaryVolumeFeature,
              let macArtifactCleanupCoordinator else {
            preconditionFailure("Tools dependencies must be installed before presenting the tools window")
        }
        NSApp.setActivationPolicy(.regular)

        let windowController = toolsWindowController ?? ToolsWindowController(
            settings: settings,
            twitchNotificationController: twitchNotificationController,
            onScreenshotShortcutChange: { [weak self] shortcut in
                self?.updateScreenshotSaveAndCopyHotKey(shortcut) ?? false
            },
            onScreenshotShortcutRecordingChanged: { [weak self] isRecording in
                self?.setScreenshotSaveAndCopyHotKeyRecording(isRecording)
            },
            clearURLsClipboardAvailable: clipboardClearURLsController != nil,
            microphoneToastOptionsMenu: statusMenuController.microphoneToastOptionsMenu,
            outputVolumeMenu: temporaryVolumeFeature.menu.menu,
            macArtifactCleanupStore: macArtifactCleanupStore,
            macArtifactCleanupCoordinator: macArtifactCleanupCoordinator,
            onCaptureScreenshot: { [weak self] in
                guard let self else { return }
                self.captureScreenshotToClipboard()
            },
            onClose: { [weak self] in
                self?.toolsWindowDidClose()
            }
        )
        toolsWindowController = windowController

        windowController.present()
        NSApp.activate()
    }

    func toolsWindowDidClose() {
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.toolsWindowController?.window,
                  !window.isVisible,
                  !window.isMiniaturized else {
                return
            }
            NSApp.setActivationPolicy(.accessory)
        }
    }

}
