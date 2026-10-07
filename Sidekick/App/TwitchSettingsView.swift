import AppKit

@MainActor
final class TwitchSettingsView: NSView {
    private let twitchNotificationView: TwitchNotificationView

    init(twitchNotificationView: TwitchNotificationView) {
        self.twitchNotificationView = twitchNotificationView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func refresh() {
        twitchNotificationView.refresh()
    }

    private func buildView() {
        let title = NSTextField(labelWithString: "Twitch")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.alignment = .left

        let detail = NSTextField(
            wrappingLabelWithString: "Manage Twitch live-stream notifications and sign-in."
        )
        detail.textColor = .secondaryLabelColor
        detail.alignment = .left

        let stack = NSStackView(views: [title, detail, twitchNotificationView])
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
}
