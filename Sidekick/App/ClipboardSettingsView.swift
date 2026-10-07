import AppKit

@MainActor
final class ClipboardSettingsView: NSView {
    private let settings: AppSettings
    private let clearURLsAvailable: Bool
    private let imageOpeningApplicationPicker: ClipboardImageOpeningApplicationPickerView
    private let webPSwitch = NSSwitch()
    private let markdownSwitch = NSSwitch()
    private let clearURLsSwitch = NSSwitch()

    init(
        settings: AppSettings,
        imageOpeningApplicationPicker: ClipboardImageOpeningApplicationPickerView,
        clearURLsAvailable: Bool
    ) {
        self.settings = settings
        self.imageOpeningApplicationPicker = imageOpeningApplicationPicker
        self.clearURLsAvailable = clearURLsAvailable
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildView()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func refresh() {
        webPSwitch.state = settings.webPClipboardConverterEnabled ? .on : .off
        markdownSwitch.state = settings.markdownClipboardCleanerEnabled ? .on : .off
        clearURLsSwitch.state = clearURLsAvailable && settings.clearURLsClipboardEnabled ? .on : .off
        clearURLsSwitch.isEnabled = clearURLsAvailable
        imageOpeningApplicationPicker.refresh()
    }

    @objc private func toggleWebP() {
        settings.webPClipboardConverterEnabled = webPSwitch.state == .on
    }

    @objc private func toggleMarkdown() {
        settings.markdownClipboardCleanerEnabled = markdownSwitch.state == .on
    }

    @objc private func toggleClearURLs() {
        settings.clearURLsClipboardEnabled = clearURLsSwitch.state == .on
    }

    private func buildView() {
        let title = NSTextField(labelWithString: "Clipboard")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.alignment = .left

        let detail = NSTextField(wrappingLabelWithString: "Choose how Sidekick handles copied content.")
        detail.textColor = .secondaryLabelColor
        detail.alignment = .left

        let sectionTitle = NSTextField(labelWithString: "Clipboard tools")
        sectionTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        sectionTitle.alignment = .left
        configureSwitches()

        let stack = NSStackView(
            views: [title, detail, imageOpeningApplicationPicker, makeSeparator(), sectionTitle] + makeToolRows()
        )
        stack.orientation = .vertical
        configureSettingsPageStack(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func configureSwitches() {
        webPSwitch.target = self
        webPSwitch.action = #selector(toggleWebP)
        webPSwitch.setAccessibilityLabel("Convert clipboard images to WebP")
        markdownSwitch.target = self
        markdownSwitch.action = #selector(toggleMarkdown)
        markdownSwitch.setAccessibilityLabel("Clean clipboard Markdown")
        clearURLsSwitch.target = self
        clearURLsSwitch.action = #selector(toggleClearURLs)
        clearURLsSwitch.setAccessibilityLabel("Clean tracking parameters from clipboard URLs")
    }

    private func makeToolRows() -> [NSView] {
        [
            makeToolRow(
                title: "Convert clipboard images to WebP",
                detail: "Convert the current clipboard image at 75% quality.",
                shortcut: "⌘⌥⇧C",
                shortcutDescription: "Command–Option–Shift–C",
                toggle: webPSwitch
            ),
            makeSeparator(),
            makeToolRow(
                title: "Clean clipboard Markdown",
                detail: "Remove Markdown formatting while preserving readable text.",
                shortcut: "⌘⌥⇧M",
                shortcutDescription: "Command–Option–Shift–M",
                toggle: markdownSwitch
            ),
            makeSeparator(),
            makeToolRow(
                title: "Clean tracking parameters from URLs",
                detail: clearURLsAvailable
                    ? "Remove common tracking parameters from copied URLs."
                    : "ClearURLs support is unavailable in this build.",
                shortcut: "Auto",
                shortcutDescription: "Runs automatically when clipboard text changes.",
                toggle: clearURLsSwitch
            )
        ]
    }

    private func makeToolRow(
        title: String,
        detail: String,
        shortcut: String,
        shortcutDescription: String,
        toggle: NSSwitch
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.alignment = .left

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .left

        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.distribution = .fill
        labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let shortcutLabel = NSTextField(labelWithString: shortcut)
        shortcutLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.toolTip = shortcutDescription

        let controls = NSStackView(views: [shortcutLabel, toggle])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.distribution = .fill
        controls.spacing = 14
        controls.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [labels, controls])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        return row
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }
}
