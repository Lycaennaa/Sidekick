import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    enum MarkdownCleaningTrigger: Equatable {
        case hotKey
        case manual
    }

    let settings = AppSettings()
    var clipboardToastController: ClipboardToastController?
    var clipboardUtilityImageWorker = ClipboardImageEnrichmentWorker()
    var clipboardImagePreviewOpener: ClipboardImagePreviewOpener?
    var clipboardWebPController: ClipboardWebPController?
    var clipboardWebPHotKey: GlobalHotKey?
    var screenshotCaptureController: ScreenshotCaptureController?
    var screenshotSaveAndClipboardHotKey: GlobalHotKey?
    var isScreenshotSaveAndCopyHotKeyRecording = false
    var isTerminating = false
    var screenshotCaptureTask: Task<Void, Never>?
    var screenshotCaptureRequestID: UUID?
    var screenshotTerminationPending = false
    var screenshotClipboardMetadataRegistry = ScreenshotClipboardMetadataRegistry()
    var clipboardMarkdownController: ClipboardMarkdownController?
    var clipboardClearURLsController: ClipboardClearURLsController?
    var activeClipboardMutationGeneration: UInt64?
    var activeMarkdownCleaning: (generation: UInt64, trigger: MarkdownCleaningTrigger)?
    var clipboardMarkdownHotKey: GlobalHotKey?
    var clipboardTokenizer: ClipboardTokenizer?
    var toastPresentationCoordinator: ToastPresentationCoordinator?

    var microphoneToastController: MicrophoneToastController?
    var temporaryVolumeFeature: TemporaryVolumeFeature?
    var statusMenuController: StatusMenuController?
    var twitchNotificationController: TwitchNotificationController?
    var toolsWindowController: ToolsWindowController?
    private var systemAppearanceObservation: NSKeyValueObservation?
    var utilityToastGeneration: UInt64 = UInt64.max / 2
    var utilityToastPresentationToken: UInt64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppTheme.apply(settings.appearance)
        observeSystemAppearanceChanges()
        installApplicationMenu()
        installClipboardFoundation()
        installClipboardToastController()
        installClipboardUtilities()
        installScreenshotCapture()
        installTwitchController()
        installTemporaryVolumeFeature()
        installStatusMenu()
        installSettingsChangeHandler()
        startServices()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        twitchNotificationController?.retryAuthorizationIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let captureTask = screenshotCaptureTask else { return .terminateNow }
        if screenshotTerminationPending {
            isTerminating = true
            stopGlobalHotKeys()
            return .terminateLater
        }

        screenshotCaptureRequestID = nil
        screenshotCaptureController?.terminate()
        captureTask.cancel()
        guard screenshotCaptureController?.hasPendingPasteboardMutation == true
                || screenshotCaptureController?.hasPendingSavePreparation == true else {
            screenshotCaptureTask = nil
            return .terminateNow
        }

        screenshotTerminationPending = true
        isTerminating = true
        stopGlobalHotKeys()
        Task { @MainActor [weak self, sender] in
            await captureTask.value
            guard let self else { return }
            self.screenshotCaptureTask = nil
            self.screenshotTerminationPending = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func stopGlobalHotKeys() {
        clipboardWebPHotKey?.stop()
        clipboardMarkdownHotKey?.stop()
        screenshotSaveAndClipboardHotKey?.stop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        stopGlobalHotKeys()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        temporaryVolumeFeature?.stop()
        microphoneToastController?.stop()
        clipboardUtilityImageWorker.cancelAll()
        if let clipboardTokenizer {
            Task {
                await clipboardTokenizer.shutdown()
            }
        }
        screenshotCaptureRequestID = nil
        screenshotCaptureTask?.cancel()
        screenshotCaptureTask = nil
        screenshotCaptureController?.terminate()
        clipboardMarkdownController?.terminate()
        clipboardWebPController?.terminate()
        clipboardImagePreviewOpener?.terminate()
        clipboardToastController?.terminate()
        clipboardClearURLsController?.terminate()
        toastPresentationCoordinator?.hideAll()
        twitchNotificationController?.terminate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showTools()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
extension AppDelegate {
    private func installClipboardFoundation() {
        let toastStackController = ToastStackController()
        toastPresentationCoordinator = ToastPresentationCoordinator(stack: toastStackController)

        let clipboardTokenizer = ClipboardTokenizer()
        self.clipboardTokenizer = clipboardTokenizer
        Task {
            try? await clipboardTokenizer.preload()
        }

        clipboardImagePreviewOpener = ClipboardImagePreviewOpener(
            settings: settings,
            onFailure: { [weak self] in
                self?.presentUtilityToast(
                    "Couldn’t open image",
                    style: .image,
                    symbolName: "photo.badge.exclamationmark"
                )
            }
        )
    }

    private func installClipboardToastController() {
        guard let clipboardTokenizer else {
            preconditionFailure("Clipboard tokenizer must be installed first")
        }

        clipboardToastController = ClipboardToastController(
            settings: settings,
            screenshotMetadataRegistry: screenshotClipboardMetadataRegistry,
            onStateChange: { [weak self] _ in self?.refreshStatusMenu() },
            onToastChange: { [weak self] model in
                guard let self else { return }
                if let model {
                    self.cancelPendingUtilityToast()
                    self.presentGeneralToast(
                        model,
                        duration: self.settings.toastDuration
                    )
                } else {
                    self.toastPresentationCoordinator?.hideGeneral()
                }
            },
            onToastUpdate: { [weak self] model in
                self?.toastPresentationCoordinator?.updateGeneral(model)
            },
            onImagePreview: { [weak self] action in
                self?.clipboardImagePreviewOpener?.open(
                    action.request,
                    isCurrent: action.isCurrent
                )
            },
            tokenizer: clipboardTokenizer
        )
    }

    private func installClipboardUtilities() {
        installWebPController()
        installMarkdownController()
        installClearURLsController()
    }

    private func installWebPController() {
        clipboardWebPController = ClipboardWebPController(
            onConverted: { [weak self] url, changeCount in
                guard let self else { return }
                let generation = self.utilityToastGeneration
                Task { @MainActor [weak self] in
                    guard let self, self.utilityToastGeneration == generation else { return }
                    self.presentConvertedWebPToast(
                        url,
                        changeCount: changeCount,
                        expectedGeneration: generation
                    )
                    await self.clipboardToastController?.acknowledgeClipboardChange(
                        changeCount,
                        matchingFile: url
                    )
                }
            },
            onMessage: { [weak self] message in
                self?.presentUtilityToast(
                    message,
                    style: .image,
                    symbolName: "photo.badge.exclamationmark"
                )
            }
        )
        clipboardWebPHotKey = GlobalHotKey(shortcut: .webPClipboard) { [weak self] in
            guard let self, self.settings.webPClipboardConverterEnabled else { return }
            self.startWebPConversion()
        }
    }

    private func installMarkdownController() {
        guard let clipboardTokenizer else {
            preconditionFailure("Clipboard tokenizer must be installed first")
        }
        clipboardMarkdownController = ClipboardMarkdownController(tokenizer: clipboardTokenizer)
        clipboardMarkdownHotKey = GlobalHotKey(shortcut: .cleanMarkdown) { [weak self] in
            guard let self, self.settings.markdownClipboardCleanerEnabled else { return }
            self.cleanMarkdownClipboard(trigger: .hotKey)
        }
    }

    private func installClearURLsController() {
        do {
            clipboardClearURLsController = try ClipboardClearURLsController(
                settings: settings,
                onResult: { [weak self] result in
                    self?.handleClearURLsResult(result)
                }
            )
        } catch {
            presentUtilityToast(
                "ClearURLs rules unavailable",
                style: .text,
                symbolName: "link.badge.xmark"
            )
        }
    }

    private func installTwitchController() {
        let controller = TwitchNotificationController(settings: settings)
        twitchNotificationController = controller
        controller.onStateChange = { [weak self] in
            self?.refreshStatusMenu()
            self?.toolsWindowController?.refreshTwitchView()
        }
        controller.onOnlineStreamsChange = { [weak self] streams in
            self?.statusMenuController?.refreshTwitchStreams(streams)
        }
        controller.onStreamLive = { [weak self] stream, profileImageData in
            self?.presentTwitchToast(for: stream, profileImageData: profileImageData)
        }
        controller.onTestProfile = { [weak self] payload in
            self?.presentTwitchProfileTest(payload)
        }
        controller.onStreamsLiveSummary = { [weak self] count in
            self?.presentTwitchSummaryToast(count: count)
        }
    }

    private func installTemporaryVolumeFeature() {
        temporaryVolumeFeature = TemporaryVolumeFeature(
            onStateChange: { [weak self] in
                self?.statusMenuController?.refreshTemporaryVolumeMenu()
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                self.presentTemporaryVolumeToast(
                    error.localizedDescription,
                    symbolName: "speaker.slash",
                    duration: self.settings.toastDuration + 1
                )
            },
            onEvent: { [weak self] event in
                guard let self else { return }
                let content = event.toastContent
                self.presentTemporaryVolumeToast(
                    content.message,
                    symbolName: content.symbolName,
                    duration: self.settings.toastDuration + 1
                )
            }
        )
    }

    private func installStatusMenu() {
        guard let clipboardToastController, let temporaryVolumeFeature else {
            preconditionFailure("Clipboard and volume features must be installed first")
        }

        statusMenuController = StatusMenuController(
            settings: settings,
            clearURLsClipboardAvailable: clipboardClearURLsController != nil,
            onShowTools: { [weak self] in self?.showTools() },
            onCleanMarkdown: { [weak self] in self?.cleanMarkdownClipboard() },
            onCaptureScreenshot: { [weak self] mode, cursorOverride in
                self?.captureScreenshotToClipboard(cursorOverride: cursorOverride, mode: mode)
            },
            onToggleTwitchNotifications: { [weak self] in
                self?.settings.twitchNotificationsEnabled.toggle()
            },
            onPause: { [weak clipboardToastController] interval in
                clipboardToastController?.pause(for: interval)
            },
            onResume: { [weak clipboardToastController] in
                clipboardToastController?.resume()
            },
            onHideMicrophoneToast: { [weak self] interval in
                guard let self else { return }
                if let interval {
                    self.microphoneToastController?.hideMicrophoneToast(for: interval)
                } else {
                    self.microphoneToastController?.hideMicrophoneToastUntilNextActivityChange()
                }
            },
            onShowMicrophoneToast: { [weak self] in
                self?.microphoneToastController?.showMicrophoneToast()
            },
            temporaryVolumeFeature: temporaryVolumeFeature,
            onQuit: { NSApp.terminate(nil) }
        )
    }

    private func installSettingsChangeHandler() {
        settings.onChange = { [weak self] in
            guard let self else { return }
            self.clipboardToastController?.applySettings()
            self.syncWebPClipboardConverter()
            self.syncMarkdownHotKey()
            self.syncClearURLsClipboardCleaner()
            self.microphoneToastController?.applySettings()
            self.refreshStatusMenu()
            self.toolsWindowController?.refreshSettings()
        }
        settings.onTwitchSettingsChange = { [weak self] in
            guard let self else { return }
            self.twitchNotificationController?.applySettings()
            self.toolsWindowController?.refreshTwitchView()
        }
        settings.onAppearanceChange = { [weak self] in
            guard let self else { return }
            AppTheme.apply(self.settings.appearance)
            self.toastPresentationCoordinator?.refreshAppearance()
            self.toolsWindowController?.refreshAppearance()
        }
    }

    private func observeSystemAppearanceChanges() {
        systemAppearanceObservation = NSApplication.shared.observe(
            \.effectiveAppearance,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.settings.appearance == .system else { return }
                self.toastPresentationCoordinator?.refreshAppearance()
                self.toolsWindowController?.refreshAppearance()
            }
        }
    }

    private func startServices() {
        syncWebPClipboardConverter()
        syncMarkdownHotKey()
        startScreenshotSaveAndClipboardHotKey()
        syncClearURLsClipboardCleaner()
        installWorkspaceObservers()
        clipboardToastController?.start()
        if let controller = twitchNotificationController {
            Task { @MainActor [weak controller] in
                await controller?.requestKeychainAccessAtStartup()
            }
        }
        guard let toastPresentationCoordinator else {
            preconditionFailure("Toast presentation coordinator must be installed first")
        }
        microphoneToastController = MicrophoneToastController(
            toastPresentationCoordinator: toastPresentationCoordinator,
            settings: settings
        )
        microphoneToastController?.start()
    }
}
