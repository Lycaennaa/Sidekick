import AppKit

@MainActor
final class ToolsWindowController: NSWindowController, NSWindowDelegate {
    private static let frameAutosaveName = "Sidekick.ToolsWindow"

    private let onClose: () -> Void
    private let sidebarController: ToolsSidebarViewController
    private let contentController: ToolsContentViewController

    private let discordInstallerView = DiscordInstallerView()
    init(
        settings: AppSettings,
        twitchNotificationController: TwitchNotificationController,
        onScreenshotShortcutChange: @escaping (GlobalHotKey.Shortcut) -> Bool,
        onScreenshotShortcutRecordingChanged: @escaping (Bool) -> Void,
        clearURLsClipboardAvailable: Bool,
        microphoneToastOptionsMenu: NSMenu,
        outputVolumeMenu: NSMenu,
        macArtifactCleanupStore: MacArtifactCleanupStore,
        macArtifactCleanupCoordinator: MacArtifactCleanupCoordinator,
        onCaptureScreenshot: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        let screenshotSaveSettingsView = ScreenshotSaveSettingsView(
            settings: settings,
            onShortcutChange: onScreenshotShortcutChange,
            onRecordingChanged: onScreenshotShortcutRecordingChanged
        )
        let imageOpeningApplicationPicker = ClipboardImageOpeningApplicationPickerView(settings: settings)
        let twitchNotificationView = TwitchNotificationView(
            settings: settings,
            controller: twitchNotificationController
        )
        let contentController = ToolsContentViewController(
            settings: settings,
            screenshotSaveSettingsView: screenshotSaveSettingsView,
            imageOpeningApplicationPicker: imageOpeningApplicationPicker,
            clearURLsClipboardAvailable: clearURLsClipboardAvailable,
            twitchNotificationView: twitchNotificationView,
            discordInstallerView: discordInstallerView,
            microphoneToastOptionsMenu: microphoneToastOptionsMenu,
            outputVolumeMenu: outputVolumeMenu,
            macArtifactCleanupStore: macArtifactCleanupStore,
            macArtifactCleanupCoordinator: macArtifactCleanupCoordinator,
            onCaptureScreenshot: onCaptureScreenshot
        )
        self.contentController = contentController

        let sidebarController = ToolsSidebarViewController()
        self.sidebarController = sidebarController
        sidebarController.onSelection = { [weak contentController] page in
            contentController?.select(page)
        }

        let splitController = NSSplitViewController()
        splitController.splitView.isVertical = true
        splitController.splitView.autosaveName = "Sidekick.ToolsWindow.SplitView"

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 240
        sidebarItem.preferredThicknessFraction = 0.22
        sidebarItem.canCollapse = false
        splitController.addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.minimumThickness = 480
        splitController.addSplitViewItem(contentItem)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sidekick"
        window.minSize = NSSize(width: 800, height: 520)
        window.backgroundColor = AppTheme.surface
        window.contentViewController = splitController
        window.isReleasedWhenClosed = false

        let restoredFrame = window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)
        if !restoredFrame {
            window.center()
        }

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func present() {
        contentController.refreshViews()
        applyAppearance()
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshSettings() {
        contentController.refreshSettings()
        applyAppearance()
    }

    func cancelDiscordOperationForTermination() -> Task<Void, Never>? {
        discordInstallerView.cancelForApplicationTermination()
    }

    func refreshTwitchView() {
        guard window?.isVisible == true else { return }
        contentController.refreshTwitchView()
    }

    func refreshAppearance() {
        contentController.refreshAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        guard let window else { return }
        window.backgroundColor = AppTheme.surface

        guard let contentView = window.contentViewController?.view else { return }
        if AppTheme.resolvedAppearance == .dark || AppTheme.resolvedAppearance == .amoledBlack {
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = AppTheme.surface.cgColor
        } else {
            contentView.layer?.backgroundColor = nil
        }
        sidebarController.applyAppearance()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
