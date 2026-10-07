import AppKit

@MainActor
final class NotificationsSettingsView: NSView {
    private let settings: AppSettings
    private let twitchNotificationView: TwitchNotificationView
    private let clipboardSwitch = NSSwitch()
    private let durationPopup = NSPopUpButton()

    init(settings: AppSettings, twitchNotificationView: TwitchNotificationView) {
        self.settings = settings
        self.twitchNotificationView = twitchNotificationView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildView()
        refreshSettings()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func refreshSettings() {
        clipboardSwitch.state = settings.clipboardToastEnabled ? .on : .off
        let selectedDuration = AppSettings.allowedToastDurations.firstIndex(of: settings.toastDuration) ?? 0
        durationPopup.selectItem(at: selectedDuration)
    }

    func refreshTwitchView() {
        twitchNotificationView.refresh()
    }

    @objc private func toggleClipboard() {
        settings.clipboardToastEnabled = clipboardSwitch.state == .on
    }

    @objc private func selectDuration() {
        guard let duration = durationPopup.selectedItem?.representedObject as? NSNumber else { return }
        settings.toastDuration = duration.doubleValue
    }

    private func buildView() {
        let title = NSTextField(labelWithString: "Notifications")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.alignment = .left

        let detail = NSTextField(
            wrappingLabelWithString: "Choose which Sidekick activity can appear as a notification."
        )
        detail.textColor = .secondaryLabelColor
        detail.alignment = .left

        let sectionTitle = NSTextField(labelWithString: "Clipboard")
        sectionTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        sectionTitle.alignment = .left

        clipboardSwitch.target = self
        clipboardSwitch.action = #selector(toggleClipboard)
        clipboardSwitch.setAccessibilityLabel("Clipboard notifications")

        durationPopup.target = self
        durationPopup.action = #selector(selectDuration)
        durationPopup.setAccessibilityLabel("Clipboard toast duration")
        for duration in AppSettings.allowedToastDurations {
            durationPopup.addItem(withTitle: Self.durationTitle(duration))
            durationPopup.lastItem?.representedObject = NSNumber(value: duration)
        }

        let stack = NSStackView(views: [
            title,
            detail,
            sectionTitle,
            makeToggleRow(
                title: "Clipboard notifications",
                detail: "Show a toast when new clipboard content is detected.",
                toggle: clipboardSwitch
            ),
            makeDurationRow(),
            makeSeparator(),
            twitchNotificationView
        ])
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

    private func makeToggleRow(title: String, detail: String, toggle: NSSwitch) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        titleLabel.alignment = .left
        detailLabel.textColor = .secondaryLabelColor

        detailLabel.alignment = .left
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

    private func makeDurationRow() -> NSView {
        let title = NSTextField(labelWithString: "Toast duration")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "How long clipboard toasts remain visible.")
        detail.textColor = .secondaryLabelColor

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.distribution = .fill
        labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labels, durationPopup])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 18
        return row
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return separator
    }

    private static func durationTitle(_ duration: TimeInterval) -> String {
        duration == duration.rounded() ? "\(Int(duration)) seconds" : "\(duration) seconds"
    }
}
