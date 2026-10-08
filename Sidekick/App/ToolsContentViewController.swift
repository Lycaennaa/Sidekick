import AppKit

@MainActor
final class ToolsContentViewController: NSViewController {
    private let clipboardView: ClipboardSettingsView
    private let screenshotView: ScreenshotSettingsView
    private let screenshotSaveSettingsView: ScreenshotSaveSettingsView
    private let twitchView: TwitchSettingsView
    private let discordInstallerView: DiscordInstallerView
    private let audioView: AudioSettingsView
    private let outputVolumeView: OutputVolumeSettingsView
    private let appearanceView: AppearanceSettingsView
    private let permissionsView = PermissionsSettingsView()
    private var pageHost: ToolsSettingsPageHost?
    private(set) var selectedPage = ToolsSettingsPage.clipboard

    init(
        settings: AppSettings,
        screenshotSaveSettingsView: ScreenshotSaveSettingsView,
        imageOpeningApplicationPicker: ClipboardImageOpeningApplicationPickerView,
        clearURLsClipboardAvailable: Bool,
        twitchNotificationView: TwitchNotificationView,
        discordInstallerView: DiscordInstallerView,
        microphoneToastOptionsMenu: NSMenu,
        outputVolumeMenu: NSMenu,
        onCaptureScreenshot: @escaping () -> Void
    ) {
        clipboardView = ClipboardSettingsView(
            settings: settings,
            imageOpeningApplicationPicker: imageOpeningApplicationPicker,
            clearURLsAvailable: clearURLsClipboardAvailable
        )
        self.screenshotSaveSettingsView = screenshotSaveSettingsView
        screenshotView = ScreenshotSettingsView(settings: settings, onCapture: onCaptureScreenshot)
        twitchView = TwitchSettingsView(twitchNotificationView: twitchNotificationView)
        self.discordInstallerView = discordInstallerView
        audioView = AudioSettingsView(
            settings: settings,
            microphoneToastOptionsMenu: microphoneToastOptionsMenu
        )
        outputVolumeView = OutputVolumeSettingsView(menu: outputVolumeMenu)
        appearanceView = AppearanceSettingsView(settings: settings)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func loadView() {
        let pages = ToolsSettingsPage.allCases.map { page -> (ToolsSettingsPage, NSView) in
            (page, Self.makeScrollablePage(content: contentView(for: page)))
        }
        let pageHost = ToolsSettingsPageHost(pages: pages, selectedPage: selectedPage)
        self.pageHost = pageHost
        view = pageHost
    }
    func select(_ page: ToolsSettingsPage) {
        selectedPage = page
        pageHost?.select(page)
        switch page {
        case .twitch:
            twitchView.refresh()
        case .discord:
            discordInstallerView.refresh()
        case .permissions:
            permissionsView.refresh()
        case .clipboard, .screenshots, .audio, .outputVolume, .appearance:
            break
        }
    }

    func refreshViews() {
        refreshSettings()
        if selectedPage == .twitch {
            twitchView.refresh()
        } else if selectedPage == .discord {
            discordInstallerView.refresh()
        }
    }

    func refreshSettings() {
        clipboardView.refresh()
        screenshotView.refresh()
        screenshotSaveSettingsView.refresh()
        twitchView.refresh()
        audioView.refresh()
        if selectedPage == .permissions {
            permissionsView.refresh()
        }
    }

    func refreshAppearance() {
        appearanceView.refresh()
        twitchView.refresh()
    }

    func refreshTwitchView() {
        guard selectedPage == .twitch else { return }
        twitchView.refresh()
    }

    private func contentView(for page: ToolsSettingsPage) -> NSView {
        switch page {
        case .clipboard: clipboardView
        case .screenshots: screenshotPage
        case .twitch: twitchView
        case .discord: discordInstallerView
        case .audio: audioView
        case .outputVolume: outputVolumeView
        case .appearance: appearanceView
        case .permissions: permissionsView
        }
    }

    private var screenshotPage: NSView {
        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [screenshotView, separator, screenshotSaveSettingsView])
        stack.orientation = .vertical
        stack.spacing = 24
        configureSettingsPageStack(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private static func makeScrollablePage(content: NSView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setContentHuggingPriority(.required, for: .vertical)
        content.setContentCompressionResistancePriority(.required, for: .vertical)
        documentView.addSubview(content)

        let contentWidth = content.widthAnchor.constraint(equalTo: documentView.widthAnchor, constant: -64)
        contentWidth.priority = .defaultHigh
        let minimumDocumentHeight = documentView.heightAnchor.constraint(
            greaterThanOrEqualTo: content.heightAnchor,
            constant: 64
        )
        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            minimumDocumentHeight,
            content.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(lessThanOrEqualTo: documentView.trailingAnchor, constant: -32),
            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 32),
            content.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -32),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 440),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 700),
            contentWidth
        ])
        return scrollView
    }
}
