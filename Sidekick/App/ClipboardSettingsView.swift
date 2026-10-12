import AppKit

@MainActor
final class ClipboardSettingsView: NSView {
    private let settings: AppSettings
    private let clearURLsAvailable: Bool
    private let imageOpeningApplicationPicker: ClipboardImageOpeningApplicationPickerView
    private let imageConversionSwitch = NSSwitch()
    private let automaticImageConversionSwitch = NSSwitch()
    private let imageOutputFormatPopup = NSPopUpButton()
    private let markdownSwitch = NSSwitch()
    private let clearURLsSwitch = NSSwitch()
    private let clipboardToastSwitch = NSSwitch()
    private let toastDurationPopup = NSPopUpButton()

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
        imageConversionSwitch.state = settings.imageConversionEnabled ? .on : .off
        automaticImageConversionSwitch.state = settings.automaticImageConversionEnabled ? .on : .off
        markdownSwitch.state = settings.markdownClipboardCleanerEnabled ? .on : .off
        clearURLsSwitch.state = clearURLsAvailable && settings.clearURLsClipboardEnabled ? .on : .off
        clearURLsSwitch.isEnabled = clearURLsAvailable
        clipboardToastSwitch.state = settings.clipboardToastEnabled ? .on : .off
        let selectedDuration = AppSettings.allowedToastDurations.firstIndex(of: settings.toastDuration) ?? 0
        toastDurationPopup.selectItem(at: selectedDuration)
        let selectedFormat = ClipboardImageFormat.allCases.firstIndex(of: settings.imageOutputFormat) ?? 0
        imageOutputFormatPopup.selectItem(at: selectedFormat)
        imageOpeningApplicationPicker.refresh()
    }

    @objc private func toggleImageConversion() {
        settings.imageConversionEnabled = imageConversionSwitch.state == .on
    }

    @objc private func toggleAutomaticImageConversion() {
        settings.automaticImageConversionEnabled = automaticImageConversionSwitch.state == .on
    }

    @objc private func selectImageOutputFormat() {
        guard let rawValue = imageOutputFormatPopup.selectedItem?.representedObject as? String,
              let format = ClipboardImageFormat(rawValue: rawValue) else {
            return
        }
        settings.imageOutputFormat = format
    }

    @objc private func toggleMarkdown() {
        settings.markdownClipboardCleanerEnabled = markdownSwitch.state == .on
    }

    @objc private func toggleClearURLs() {
        settings.clearURLsClipboardEnabled = clearURLsSwitch.state == .on
    }

    @objc private func toggleClipboardToast() {
        settings.clipboardToastEnabled = clipboardToastSwitch.state == .on
    }

    @objc private func selectToastDuration() {
        guard let duration = toastDurationPopup.selectedItem?.representedObject as? NSNumber else { return }
        settings.toastDuration = duration.doubleValue
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
            views: [
                title,
                detail,
                imageOpeningApplicationPicker,
                makeSeparator(),
                sectionTitle,
                makeImageOutputFormatRow(),
                makeSeparator()
            ] + makeToolRows() + [
                makeSeparator(),
                makeClipboardNotificationSettings()
            ]
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
        imageConversionSwitch.target = self
        imageConversionSwitch.action = #selector(toggleImageConversion)
        imageConversionSwitch.setAccessibilityLabel("Convert clipboard images")
        automaticImageConversionSwitch.target = self
        automaticImageConversionSwitch.action = #selector(toggleAutomaticImageConversion)
        automaticImageConversionSwitch.setAccessibilityLabel("Automatically convert clipboard images")
        imageOutputFormatPopup.target = self
        imageOutputFormatPopup.action = #selector(selectImageOutputFormat)
        imageOutputFormatPopup.setAccessibilityLabel("Image output format")
        for format in ClipboardImageFormat.allCases {
            imageOutputFormatPopup.addItem(withTitle: format.displayName)
            imageOutputFormatPopup.lastItem?.representedObject = format.rawValue
        }
        markdownSwitch.action = #selector(toggleMarkdown)
        markdownSwitch.setAccessibilityLabel("Clean clipboard Markdown")
        clearURLsSwitch.target = self
        clearURLsSwitch.action = #selector(toggleClearURLs)
        clearURLsSwitch.setAccessibilityLabel("Clean tracking parameters from clipboard URLs")
        clipboardToastSwitch.target = self
        clipboardToastSwitch.action = #selector(toggleClipboardToast)
        clipboardToastSwitch.setAccessibilityLabel("Clipboard notifications")
        toastDurationPopup.target = self
        toastDurationPopup.action = #selector(selectToastDuration)
        toastDurationPopup.setAccessibilityLabel("Clipboard toast duration")
        for duration in AppSettings.allowedToastDurations {
            toastDurationPopup.addItem(withTitle: Self.durationTitle(duration))
            toastDurationPopup.lastItem?.representedObject = NSNumber(value: duration)
        }
    }
    private func makeImageOutputFormatRow() -> NSView {
        let title = NSTextField(labelWithString: "Image output format")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = NSTextField(
            wrappingLabelWithString: "Used for clipboard conversions and encoded screenshots."
        )
        detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labels, imageOutputFormatPopup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        return row
    }

    private func makeClipboardNotificationSettings() -> NSView {
        let title = NSTextField(labelWithString: "Clipboard notifications")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.alignment = .left

        let notificationRow = makeToggleRow(
            title: "Clipboard notifications",
            detail: "Show a toast when new clipboard content is detected.",
            toggle: clipboardToastSwitch
        )

        let durationTitle = NSTextField(labelWithString: "Toast duration")
        durationTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        let durationDetail = NSTextField(
            wrappingLabelWithString: "How long clipboard toasts remain visible."
        )
        durationDetail.textColor = .secondaryLabelColor
        let durationLabels = NSStackView(views: [durationTitle, durationDetail])
        durationLabels.orientation = .vertical
        durationLabels.alignment = .leading
        durationLabels.distribution = .fill
        durationLabels.spacing = 4
        durationLabels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let durationRow = NSStackView(views: [durationLabels, toastDurationPopup])
        durationRow.orientation = .horizontal
        durationRow.alignment = .centerY
        durationRow.distribution = .fill
        durationRow.spacing = 18

        let stack = NSStackView(views: [title, notificationRow, durationRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 12
        return stack
    }

    private func makeToggleRow(title: String, detail: String, toggle: NSSwitch) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.distribution = .fill
        labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labels, toggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 18
        return row
    }

    private static func durationTitle(_ duration: TimeInterval) -> String {
        duration == duration.rounded() ? "\(Int(duration)) seconds" : "\(duration) seconds"
    }

    private func makeToolRows() -> [NSView] {
        [
            makeToolRow(
                title: "Convert clipboard images",
                detail: "Convert the current clipboard image to the selected output format.",
                shortcut: "⌘⌥⇧C",
                shortcutDescription: "Command–Option–Shift–C",
                toggle: imageConversionSwitch
            ),
            makeSeparator(),
            makeToolRow(
                title: "Automatically convert clipboard images",
                detail: "Convert new clipboard images to the selected output format and replace the clipboard.",
                shortcut: "Auto",
                shortcutDescription: "Runs when new image content appears on the clipboard.",
                toggle: automaticImageConversionSwitch
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
