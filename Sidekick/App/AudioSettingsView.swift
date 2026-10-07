import AppKit

@MainActor
final class AudioSettingsView: NSView {
    private let settings: AppSettings
    private let microphoneToastOptionsMenu: NSMenu
    private let microphoneSwitch = NSSwitch()
    private var microphoneOptionsButton: NSButton?

    init(settings: AppSettings, microphoneToastOptionsMenu: NSMenu) {
        self.settings = settings
        self.microphoneToastOptionsMenu = microphoneToastOptionsMenu
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
        microphoneSwitch.state = settings.microphoneToastEnabled ? .on : .off
        microphoneOptionsButton?.isEnabled = settings.microphoneToastEnabled
    }

    @objc private func toggleMicrophoneStatus() {
        settings.microphoneToastEnabled = microphoneSwitch.state == .on
    }

    @objc private func showMicrophoneOptions(_ sender: NSButton) {
        guard settings.microphoneToastEnabled else { return }
        _ = microphoneToastOptionsMenu.popUp(
            positioning: nil,
            at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY),
            in: sender
        )
    }

    private func buildView() {
        let title = NSTextField(labelWithString: "Audio")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.alignment = .left

        let detail = NSTextField(
            wrappingLabelWithString: "See when applications are using your microphone."
        )
        detail.textColor = .secondaryLabelColor
        detail.alignment = .left

        let sectionTitle = NSTextField(labelWithString: "Microphone activity")
        sectionTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        sectionTitle.alignment = .left

        let stack = NSStackView(views: [
            title,
            detail,
            sectionTitle,
            makeMicrophoneRow(),
            makeMicrophoneOptionsRow()
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

    private func makeMicrophoneRow() -> NSView {
        let rowTitle = NSTextField(labelWithString: "Show microphone status notifications")
        rowTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        rowTitle.alignment = .left
        let rowDetail = NSTextField(
            wrappingLabelWithString: "Show a toast when an application starts or stops using the microphone."
        )
        rowDetail.textColor = .secondaryLabelColor
        rowDetail.alignment = .left
        let labels = NSStackView(views: [rowTitle, rowDetail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        microphoneSwitch.target = self
        microphoneSwitch.action = #selector(toggleMicrophoneStatus)
        microphoneSwitch.setAccessibilityLabel("Show microphone status notifications")

        let row = NSStackView(views: [labels, microphoneSwitch])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 18
        return row
    }

    private func makeMicrophoneOptionsRow() -> NSView {
        let optionsTitle = NSTextField(labelWithString: "Microphone toast controls")
        optionsTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        optionsTitle.alignment = .left
        let optionsDetail = NSTextField(
            wrappingLabelWithString: "Hide alerts temporarily or show one immediately."
        )
        optionsDetail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [optionsTitle, optionsDetail])
        labels.orientation = .vertical
        optionsDetail.alignment = .left
        labels.alignment = .leading
        labels.distribution = .fill
        labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let button = NSButton(
            title: "Toast Options…",
            target: self,
            action: #selector(showMicrophoneOptions(_:))
        )
        button.isEnabled = settings.microphoneToastEnabled
        microphoneOptionsButton = button

        let row = NSStackView(views: [labels, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 18
        return row
    }
}
