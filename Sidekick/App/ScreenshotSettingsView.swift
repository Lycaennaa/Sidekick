import AppKit

@MainActor
final class ScreenshotSettingsView: NSView {
    private let settings: AppSettings
    private let onCapture: () -> Void
    private let cursorSwitch = NSSwitch()

    init(settings: AppSettings, onCapture: @escaping () -> Void) {
        self.settings = settings
        self.onCapture = onCapture
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
        cursorSwitch.state = settings.screenshotCursorIncludedByDefault ? .on : .off
    }

    @objc private func toggleCursor() {
        settings.screenshotCursorIncludedByDefault = cursorSwitch.state == .on
    }

    @objc private func captureDisplay() {
        onCapture()
    }

    private func makeCaptureRow() -> NSView {
        let title = NSTextField(labelWithString: "Capture display to clipboard")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: "Select an area after capture to copy it.")
        detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let captureButton = NSButton(
            title: "Capture Now",
            target: self,
            action: #selector(captureDisplay)
        )
        captureButton.setAccessibilityLabel("Capture display to clipboard")

        let shortcutLabel = NSTextField(labelWithString: "⌘⌥⇧4")
        shortcutLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.toolTip = "Command–Option–Shift–4"
        let controls = NSStackView(views: [shortcutLabel, captureButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 14
        controls.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [labels, controls])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        return row
    }

    private func makeCursorRow() -> NSView {
        let title = NSTextField(labelWithString: "Include cursor by default")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = NSTextField(
            wrappingLabelWithString: "Use this setting when capturing from the menu bar or keyboard shortcut."
        )
        detail.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        cursorSwitch.target = self
        cursorSwitch.action = #selector(toggleCursor)
        cursorSwitch.setAccessibilityLabel("Include cursor in screenshots by default")

        let row = NSStackView(views: [labels, cursorSwitch])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        return row
    }

    private func buildView() {
        let title = NSTextField(labelWithString: "Screenshots")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.alignment = .left

        let detail = NSTextField(
            wrappingLabelWithString: "Capture the active display and copy it to the clipboard."
        )
        detail.textColor = .secondaryLabelColor
        detail.alignment = .left

        let stack = NSStackView(views: [
            title,
            detail,
            makeSeparator(),
            makeCaptureRow(),
            makeSeparator(),
            makeCursorRow()
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

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }
}
