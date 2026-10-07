import AppKit
import Carbon.HIToolbox

@MainActor
final class ScreenshotHotKeyRecorderView: NSView {
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let recordButton = NSButton(title: "Record…", target: nil, action: nil)
    private let defaultButton = NSButton(title: "Default", target: nil, action: nil)
    private let onShortcutChange: (GlobalHotKey.Shortcut) -> Bool
    private let onRecordingChanged: (Bool) -> Void
    private var currentShortcut: GlobalHotKey.Shortcut
    private var isRecording = false

    init(
        shortcut: GlobalHotKey.Shortcut,
        onShortcutChange: @escaping (GlobalHotKey.Shortcut) -> Bool,
        onRecordingChanged: @escaping (Bool) -> Void
    ) {
        currentShortcut = shortcut
        self.onShortcutChange = onShortcutChange
        self.onRecordingChanged = onRecordingChanged
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildView()
        refresh(shortcut: shortcut)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    func refresh(shortcut: GlobalHotKey.Shortcut) {
        currentShortcut = shortcut
        shortcutLabel.stringValue = shortcut.displayName
        if !isRecording {
            statusLabel.stringValue = ""
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        handleRecordingKey(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        handleRecordingKey(event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, isRecording {
            finishRecording(with: nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        statusLabel.stringValue = "Press a letter or number with ⌘, ⌥, or ⌃. Esc cancels."
        onRecordingChanged(true)
        window?.makeFirstResponder(self)
    }

    @objc private func restoreDefault() {
        finishRecording(with: .screenshotSaveAndClipboard)
    }

    private func handleRecordingKey(_ event: NSEvent) {
        guard event.keyCode != UInt16(kVK_Escape) else {
            finishRecording(with: nil)
            return
        }
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        guard let keyName = event.charactersIgnoringModifiers?.uppercased(),
              let shortcut = GlobalHotKey.Shortcut.recorded(
                keyCode: UInt32(event.keyCode),
                modifiers: modifiers,
                keyName: keyName
              ) else {
            statusLabel.stringValue = "Choose an available letter or number with ⌘, ⌥, or ⌃."
            return
        }
        finishRecording(with: shortcut)
    }

    private func finishRecording(with shortcut: GlobalHotKey.Shortcut?) {
        guard isRecording || shortcut != nil else { return }
        isRecording = false
        if let shortcut {
            if onShortcutChange(shortcut) {
                refresh(shortcut: shortcut)
                statusLabel.stringValue = ""
            } else {
                shortcutLabel.stringValue = currentShortcut.displayName
                statusLabel.stringValue = "Shortcut unavailable; previous setting retained."
            }
        } else {
            shortcutLabel.stringValue = currentShortcut.displayName
            statusLabel.stringValue = ""
        }
        onRecordingChanged(false)
    }

    private func buildView() {
        recordButton.target = self
        recordButton.action = #selector(beginRecording)
        defaultButton.target = self
        defaultButton.action = #selector(restoreDefault)
        shortcutLabel.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        shortcutLabel.setAccessibilityLabel("Save-and-copy screenshot shortcut")
        let row = NSStackView(views: [shortcutLabel, recordButton, defaultButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let stack = NSStackView(views: [row, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
}
