import AppKit

@MainActor
final class AppearanceSettingsView: NSView {
    private let settings: AppSettings
    private var appearanceButtons: [AppAppearance: NSButton] = [:]

    init(settings: AppSettings) {
        self.settings = settings
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
        for (appearance, button) in appearanceButtons {
            button.state = settings.appearance == appearance ? .on : .off
        }
    }

    @objc private func selectAppearance(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let appearance = AppAppearance(rawValue: identifier) else {
            return
        }
        settings.appearance = appearance
        refresh()
    }

    private func buildView() {
        let title = NSTextField(labelWithString: "Appearance")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.alignment = .left

        let detail = NSTextField(
            wrappingLabelWithString: "Match macOS uses Sidekick Light/Dark and follows macOS appearance changes."
        )
        detail.textColor = .secondaryLabelColor
        detail.alignment = .left

        let sectionTitle = NSTextField(labelWithString: "Theme")
        sectionTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        sectionTitle.alignment = .left

        let options = AppAppearance.allCases.map(makeOption)
        let stack = NSStackView(views: [title, detail, sectionTitle] + options)
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

    private func makeOption(_ appearance: AppAppearance) -> NSView {
        let button = NSButton(
            radioButtonWithTitle: appearance.title,
            target: self,
            action: #selector(selectAppearance(_:))
        )
        button.identifier = NSUserInterfaceItemIdentifier(appearance.rawValue)
        appearanceButtons[appearance] = button

        let detail = NSTextField(wrappingLabelWithString: appearance.detail)
        detail.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: 12)
        detail.alignment = .left

        let option = NSStackView(views: [button, detail])
        option.orientation = .vertical
        option.alignment = .leading
        option.distribution = .fill
        option.spacing = 4
        detail.leadingAnchor.constraint(equalTo: option.leadingAnchor, constant: 22).isActive = true
        detail.widthAnchor.constraint(equalTo: option.widthAnchor, constant: -22).isActive = true
        return option
    }
}
