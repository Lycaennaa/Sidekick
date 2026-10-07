import AppKit

@MainActor
final class OutputVolumeSettingsView: NSView {
    private let outputVolumeMenu: NSMenu

    init(menu: NSMenu) {
        outputVolumeMenu = menu
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    @objc private func showVolumeMenu(_ sender: NSButton) {
        _ = outputVolumeMenu.popUp(
            positioning: nil,
            at: NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY),
            in: sender
        )
    }

    private func buildView() {
        let title = NSTextField(labelWithString: "Output Volume")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.alignment = .left

        let detail = NSTextField(
            wrappingLabelWithString: "Temporarily mute an output device or schedule a mute."
        )
        detail.textColor = .secondaryLabelColor
        detail.alignment = .left

        let menuButton = NSButton(
            title: "Choose Output Device…",
            target: self,
            action: #selector(showVolumeMenu(_:))
        )
        menuButton.setAccessibilityLabel("Show temporary output volume controls")

        let controlDetail = NSTextField(
            wrappingLabelWithString: "Choose a device to mute now, schedule a mute, or restore volume."
        )
        controlDetail.textColor = .secondaryLabelColor
        controlDetail.alignment = .left

        let stack = NSStackView(views: [title, detail, menuButton, controlDetail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            detail.widthAnchor.constraint(equalTo: stack.widthAnchor),
            controlDetail.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
}
