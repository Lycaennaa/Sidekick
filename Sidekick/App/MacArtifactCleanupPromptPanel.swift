import AppKit

@MainActor
final class MacArtifactCleanupPromptPanel: NSObject, NSWindowDelegate {
    struct Button {
        let title: String
        let action: (@MainActor () -> Void)?

        init(title: String, action: (@MainActor () -> Void)? = nil) {
            self.title = title
            self.action = action
        }

    }

    let window: NSPanel
    var onDismiss: (@MainActor () -> Void)?
    var onClose: (@MainActor () -> Void)?

    private var didFinish = false
    private let buttons: [Button]

    init(title: String, detail: String, buttons: [Button]) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window = panel
        self.buttons = buttons
        super.init()
        panel.title = "Mac cleanup"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        installContent(title: title, detail: detail, buttons: buttons)
    }

    private func installContent(title: String, detail: String, buttons: [Button]) {
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        let detailView = makeDetailView(detail)
        let scrollView = NSScrollView()
        scrollView.documentView = detailView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let buttonRow = makeButtonRow(buttons)

        let contentView = NSView()
        let content = NSStackView(views: [heading, scrollView, buttonRow])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView
        contentView.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            heading.widthAnchor.constraint(equalToConstant: 480),
            scrollView.widthAnchor.constraint(equalTo: heading.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 175),
            buttonRow.widthAnchor.constraint(equalTo: heading.widthAnchor)
        ])
    }

    private func makeDetailView(_ detail: String) -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 175))
        textView.string = detail
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 480,
            height: CGFloat.greatestFiniteMagnitude
        )
        return textView
    }

    private func makeButtonRow(_ choices: [Button]) -> NSStackView {
        let buttons = choices.enumerated().map { index, choice in
            let button = NSButton(title: choice.title, target: self, action: #selector(selectButton(_:)))
            button.tag = index
            return button
        }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fillEqually
        row.spacing = 8
        return row
    }

    func show(cascadeOffset: CGFloat = 0) {
        window.center()
        if cascadeOffset != 0 {
            var frame = window.frame
            frame.origin.x += cascadeOffset
            frame.origin.y -= cascadeOffset
            window.setFrame(frame, display: false)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    @objc private func selectButton(_ sender: NSButton) {
        guard buttons.indices.contains(sender.tag) else { return }
        finish(button: buttons[sender.tag], closeWindow: true)
    }

    func windowWillClose(_ notification: Notification) {
        finish(button: nil, closeWindow: false)
    }

    private func finish(button: Button?, closeWindow: Bool) {
        guard !didFinish else { return }
        didFinish = true
        let onDismiss = onDismiss
        let onClose = onClose
        self.onDismiss = nil
        self.onClose = nil
        if closeWindow {
            window.close()
        }
        onDismiss?()
        if let button {
            button.action?()
        } else {
            onClose?()
        }
    }
}
