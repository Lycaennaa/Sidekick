import AppKit

@MainActor
final class ScreenshotSaveSettingsView: NSView, NSTextFieldDelegate {
    private let settings: AppSettings
    private let folderLabel = NSTextField(wrappingLabelWithString: "")
    private let templateField = NSTextField()
    private let shortcutRecorder: ScreenshotHotKeyRecorderView

    init(
        settings: AppSettings,
        onShortcutChange: @escaping (GlobalHotKey.Shortcut) -> Bool,
        onRecordingChanged: @escaping (Bool) -> Void
    ) {
        self.settings = settings
        shortcutRecorder = ScreenshotHotKeyRecorderView(
            shortcut: settings.screenshotSaveAndCopyShortcut,
            onShortcutChange: onShortcutChange,
            onRecordingChanged: onRecordingChanged
        )
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildView()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh() {
        folderLabel.stringValue = settings.screenshotSaveDirectoryURL.path
        folderLabel.toolTip = folderLabel.stringValue
        templateField.stringValue = settings.screenshotFilenameTemplate
        shortcutRecorder.refresh(shortcut: settings.screenshotSaveAndCopyShortcut)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === templateField else { return }
        settings.screenshotFilenameTemplate = templateField.stringValue
        refresh()
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.screenshotSaveDirectoryURL
        panel.prompt = "Choose Folder"
        panel.message = "Choose where saved screenshots are written."
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.settings.screenshotSaveDirectoryURL = url
            self.refresh()
        }
    }

    private func buildView() {
        let title = NSTextField(labelWithString: "Screenshot Saving")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let description = NSTextField(
            wrappingLabelWithString: "C copies area; Shift-C details; F full screen. Save & Copy saves."
        )
        description.textColor = .secondaryLabelColor

        let shortcutTitle = NSTextField(labelWithString: "Save-and-copy shortcut:")
        let shortcutRow = NSStackView(views: [shortcutTitle, shortcutRecorder])
        shortcutRow.orientation = .horizontal
        shortcutRow.alignment = .centerY
        shortcutRow.spacing = 8

        let folderTitle = NSTextField(labelWithString: "Save folder:")
        let chooseFolderButton = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        let folderRow = NSStackView(views: [folderTitle, folderLabel, chooseFolderButton])
        folderRow.orientation = .horizontal
        folderRow.alignment = .centerY
        folderRow.spacing = 8

        let templateTitle = NSTextField(labelWithString: "Filename template:")
        templateField.delegate = self
        templateField.placeholderString = ScreenshotFilenameTemplate.defaultTemplate
        let help = NSTextField(
            wrappingLabelWithString: "Tokens: {date}, {time}. Adds the selected output format."
        )
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: 12)

        let stack = NSStackView(
            views: [title, description, shortcutRow, folderRow, templateTitle, templateField, help]
        )
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
            shortcutRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            folderRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            folderLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            templateField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
}
