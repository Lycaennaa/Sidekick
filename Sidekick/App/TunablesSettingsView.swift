import AppKit

@MainActor
final class TunablesSettingsView: NSView, NSComboBoxDelegate {
    private let settings: AppSettings
    private let utilityToastDurationInput = NSComboBox()
    private let twitchToastDurationInput = NSComboBox()
    private let twitchPollIntervalInput = NSComboBox()
    private let clipboardImageQualityInput = NSComboBox()
    private let screenshotImageQualityInput = NSComboBox()

    init(settings: AppSettings) {
        self.settings = settings
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        configureInputs()
        buildView()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func refresh() {
        utilityToastDurationInput.stringValue = Self.numberTitle(settings.toastDuration)
        twitchToastDurationInput.stringValue = Self.numberTitle(settings.twitchToastDuration)
        twitchPollIntervalInput.stringValue = Self.numberTitle(settings.twitchPollInterval)
        clipboardImageQualityInput.stringValue = Self.qualityTitle(settings.clipboardImageQuality)
        screenshotImageQualityInput.stringValue = Self.qualityTitle(settings.screenshotImageQuality)
    }

    @objc private func setUtilityToastDuration() {
        guard let duration = Self.secondsValue(from: utilityToastDurationInput.stringValue) else {
            refresh()
            return
        }
        settings.toastDuration = duration
        refresh()
    }

    @objc private func setTwitchToastDuration() {
        guard let duration = Self.secondsValue(from: twitchToastDurationInput.stringValue) else {
            refresh()
            return
        }
        settings.twitchToastDuration = duration
        refresh()
    }

    @objc private func setTwitchPollInterval() {
        guard let interval = Self.secondsValue(from: twitchPollIntervalInput.stringValue) else {
            refresh()
            return
        }
        settings.twitchPollInterval = interval
        refresh()
    }

    @objc private func setClipboardImageQuality() {
        guard let quality = Self.percentageValue(from: clipboardImageQualityInput.stringValue),
              ClipboardImageConversionPolicy.isValidQuality(quality) else {
            refresh()
            return
        }
        settings.clipboardImageQuality = quality
        refresh()
    }

    @objc private func setScreenshotImageQuality() {
        guard let quality = Self.percentageValue(from: screenshotImageQualityInput.stringValue),
              ClipboardImageConversionPolicy.isValidQuality(quality) else {
            refresh()
            return
        }
        settings.screenshotImageQuality = quality
        refresh()
    }

    private func configureInputs() {
        configureInput(
            utilityToastDurationInput,
            accessibilityLabel: "Utility toast duration in seconds",
            values: AppSettings.toastDurationPresets,
            title: Self.numberTitle,
            action: #selector(setUtilityToastDuration)
        )
        configureInput(
            twitchToastDurationInput,
            accessibilityLabel: "Twitch toast duration in seconds",
            values: AppSettings.twitchToastDurationPresets,
            title: Self.numberTitle,
            action: #selector(setTwitchToastDuration)
        )
        configureInput(
            twitchPollIntervalInput,
            accessibilityLabel: "Twitch poll frequency in seconds",
            values: TwitchPollFrequency.intervalPresets,
            title: Self.numberTitle,
            action: #selector(setTwitchPollInterval)
        )
        configureInput(
            clipboardImageQualityInput,
            accessibilityLabel: "Clipboard image quality percentage",
            values: ClipboardImageConversionPolicy.qualityPresets,
            title: Self.qualityTitle,
            action: #selector(setClipboardImageQuality)
        )
        configureInput(
            screenshotImageQualityInput,
            accessibilityLabel: "Screenshot image quality percentage",
            values: ClipboardImageConversionPolicy.qualityPresets,
            title: Self.qualityTitle,
            action: #selector(setScreenshotImageQuality)
        )
    }

    private func configureInput(
        _ input: NSComboBox,
        accessibilityLabel: String,
        values: [Double],
        title: (Double) -> String,
        action: Selector
    ) {
        input.isEditable = true
        input.delegate = self
        input.target = self
        input.action = action
        input.setAccessibilityLabel(accessibilityLabel)
        input.identifier = NSUserInterfaceItemIdentifier(accessibilityLabel)
        input.addItems(withObjectValues: values.map(title))
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let input = notification.object as? NSComboBox else { return }
        if input === utilityToastDurationInput {
            setUtilityToastDuration()
        } else if input === twitchToastDurationInput {
            setTwitchToastDuration()
        } else if input === twitchPollIntervalInput {
            setTwitchPollInterval()
        } else if input === clipboardImageQualityInput {
            setClipboardImageQuality()
        } else if input === screenshotImageQualityInput {
            setScreenshotImageQuality()
        }
    }

    private func buildView() {
        let title = NSTextField(labelWithString: "Tunables")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.alignment = .left

        let detail = NSTextField(
            wrappingLabelWithString: "Choose a suggested value or type a custom numeric value."
        )
        detail.textColor = .secondaryLabelColor
        detail.alignment = .left

        let imageQualityTitle = Self.sectionTitle("Image quality")
        let clipboardQualityRow = makeNumericRow(
            title: "Clipboard image quality",
            detail: "Enter a percentage from 0 to 100. Higher quality may increase file size.",
            input: clipboardImageQualityInput
        )
        let screenshotQualityRow = makeNumericRow(
            title: "Screenshot image quality",
            detail: "Enter a percentage from 0 to 100. Used for WebP or AVIF output.",
            input: screenshotImageQualityInput
        )

        let notificationTimingTitle = Self.sectionTitle("Notification timing")
        let utilityToastRow = makeNumericRow(
            title: "Utility toast duration",
            detail: "Seconds; enter any positive value. Applies to clipboard and screenshot feedback.",
            input: utilityToastDurationInput
        )
        let twitchToastRow = makeNumericRow(
            title: "Twitch toast duration",
            detail: "Seconds; enter any positive value.",
            input: twitchToastDurationInput
        )
        let twitchPollIntervalRow = makeNumericRow(
            title: "Twitch poll frequency",
            detail: "Seconds between checks; enter 30 or more. Longer intervals reduce API traffic.",
            input: twitchPollIntervalInput
        )

        let stack = NSStackView(views: [
            title,
            detail,
            imageQualityTitle,
            clipboardQualityRow,
            screenshotQualityRow,
            notificationTimingTitle,
            utilityToastRow,
            twitchToastRow,
            twitchPollIntervalRow
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
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

    private func makeNumericRow(title: String, detail: String, input: NSComboBox) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labels, input])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        return row
    }

    private static func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.alignment = .left
        return label
    }

    private static func secondsValue(from text: String) -> Double? {
        var number = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercase = number.lowercased()
        if lowercase.hasSuffix(" seconds") {
            number = String(number.dropLast(" seconds".count))
        } else if lowercase.hasSuffix("s") {
            number = String(number.dropLast())
        }
        guard let value = numericValue(from: number), value > 0 else { return nil }
        return value
    }

    private static func percentageValue(from text: String) -> Double? {
        var number = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if number.hasSuffix("%") {
            number = String(number.dropLast())
        }
        guard let percentage = numericValue(from: number), (0...100).contains(percentage) else { return nil }
        return percentage / 100
    }

    private static func numericValue(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let decimalSeparator = Locale.current.decimalSeparator ?? "."
        let normalized = decimalSeparator == "."
            ? trimmed
            : trimmed.replacingOccurrences(of: decimalSeparator, with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }

    private static func numberTitle(_ value: Double) -> String {
        if value >= 0, value < Double(Int.max), value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }

    private static func qualityTitle(_ quality: Double) -> String {
        "\(numberTitle(quality * 100))%"
    }
}
