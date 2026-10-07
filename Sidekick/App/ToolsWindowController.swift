import AppKit

@MainActor
final class ToolsWindowController: NSWindowController, NSWindowDelegate {
    private static let frameAutosaveName = "Sidekick.ToolsWindow"

    private let onClose: () -> Void
    private let twitchNotificationView: TwitchNotificationView
    private let imageOpeningApplicationPicker: ClipboardImageOpeningApplicationPickerView
    private let screenshotSaveSettingsView: ScreenshotSaveSettingsView

    init(
        settings: AppSettings,
        twitchNotificationController: TwitchNotificationController,
        onScreenshotShortcutChange: @escaping (GlobalHotKey.Shortcut) -> Bool,
        onScreenshotShortcutRecordingChanged: @escaping (Bool) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        self.imageOpeningApplicationPicker = ClipboardImageOpeningApplicationPickerView(settings: settings)
        self.screenshotSaveSettingsView = ScreenshotSaveSettingsView(
            settings: settings,
            onShortcutChange: onScreenshotShortcutChange,
            onRecordingChanged: onScreenshotShortcutRecordingChanged
        )
        self.twitchNotificationView = TwitchNotificationView(
            settings: settings,
            controller: twitchNotificationController
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sidekick"
        window.minSize = NSSize(width: 560, height: 360)
        window.isReleasedWhenClosed = false
        window.contentView = Self.makeContentView(
            screenshotSaveSettingsView: screenshotSaveSettingsView,
            imageOpeningApplicationPicker: imageOpeningApplicationPicker,
            twitchNotificationView: twitchNotificationView
        )

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
        imageOpeningApplicationPicker.refresh()
        twitchNotificationView.refresh()
        screenshotSaveSettingsView.refresh()
        window?.deminiaturize(nil)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func refreshTwitchView() {
        twitchNotificationView.refresh()
    }

    func refreshScreenshotSaveSettingsView() {
        screenshotSaveSettingsView.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    private static func makeContentView(
        screenshotSaveSettingsView: ScreenshotSaveSettingsView,
        imageOpeningApplicationPicker: ClipboardImageOpeningApplicationPickerView,
        twitchNotificationView: TwitchNotificationView
    ) -> NSView {
        let contentView = NSView()
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        contentView.addSubview(scrollView)

        let stack = makeContentStack(
            screenshotSaveSettingsView: screenshotSaveSettingsView,
            imageOpeningApplicationPicker: imageOpeningApplicationPicker,
            twitchNotificationView: twitchNotificationView
        )
        documentView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor, constant: 40),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -40),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 40),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -40),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 400)
        ])
        return contentView
    }

    private static func makeContentStack(
        screenshotSaveSettingsView: ScreenshotSaveSettingsView,
        imageOpeningApplicationPicker: ClipboardImageOpeningApplicationPickerView,
        twitchNotificationView: TwitchNotificationView
    ) -> NSStackView {
        let screenshotTool = makeToolView(
            title: "Screenshot Selection",
            detail: "Draw a region; C copies it. F captures full screen. Save & Copy saves the area.",
            shortcut: "C / F",
            shortcutDescription: "Shift-C copies pixel details; the menu offers selection-only copy."
        )
        let webPTool = makeToolView(
            title: "Clipboard Image to WebP",
            detail: "Convert the current clipboard image to WebP at 75% quality.",
            shortcut: "⌘⌥⇧C",
            shortcutDescription: "Command–Option–Shift–C"
        )
        let markdownTool = makeToolView(
            title: "Clean Clipboard Markdown",
            detail: "Remove Markdown formatting while preserving readable text.",
            shortcut: "⌘⌥⇧M",
            shortcutDescription: "Command–Option–Shift–M"
        )
        let imageOpeningSeparator = NSBox()
        imageOpeningSeparator.boxType = .separator
        let webPSeparator = NSBox()
        webPSeparator.boxType = .separator
        let markdownSeparator = NSBox()
        markdownSeparator.boxType = .separator
        let screenshotToolSeparator = NSBox()
        screenshotToolSeparator.boxType = .separator
        let screenshotSettingsSeparator = NSBox()
        screenshotSettingsSeparator.boxType = .separator
        let stack = NSStackView(
            views: [
                screenshotTool,
                screenshotToolSeparator,
                screenshotSaveSettingsView,
                screenshotSettingsSeparator,
                imageOpeningApplicationPicker,
                imageOpeningSeparator,
                webPTool,
                webPSeparator,
                markdownTool,
                markdownSeparator,
                twitchNotificationView
            ]
        )
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private static func makeToolView(
        title: String,
        detail: String,
        shortcut: String,
        shortcutDescription: String
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.alignment = .center

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center

        let shortcutLabel = NSTextField(labelWithString: shortcut)
        shortcutLabel.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        shortcutLabel.alignment = .center
        shortcutLabel.toolTip = shortcutDescription

        let stack = NSStackView(views: [titleLabel, detailLabel, shortcutLabel])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        return stack
    }
}
