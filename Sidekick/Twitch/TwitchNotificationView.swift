import AppKit

@MainActor
final class TwitchNotificationView: NSView, NSTextFieldDelegate {
    private let settings: AppSettings
    private let controller: TwitchNotificationController
    private let channelSelectionView: TwitchFollowedChannelSelectionView
    private let enabledSwitch = NSSwitch()
    private let tokenField = NSTextField(string: "")
    private let usernameField = NSTextField(string: "")
    private let oauthClientIDField = NSTextField(string: "")
    private let saveOAuthClientIDButton = NSButton(title: "Save ID", target: nil, action: nil)
    private let clearOAuthClientIDButton = NSButton(title: "Use App/Source", target: nil, action: nil)
    private let oauthClientIDHintLabel = NSTextField(
        wrappingLabelWithString: "Optional public client ID. Leave blank to use app/source configuration."
    )

    private let getOAuthTokenButton = NSButton(title: "Get Token from Twitch", target: nil, action: nil)
    private let browserFallbackButton = NSButton(title: "Use Browser Fallback", target: nil, action: nil)
    private let saveTokenButton = NSButton(title: "Save Token", target: nil, action: nil)
    private let removeTokenButton = NSButton(title: "Remove", target: nil, action: nil)
    private let testNotificationButton = NSButton(title: "Send Test Notification", target: nil, action: nil)
    private let tokenStatusLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let oauthConfigurationLabel = NSTextField(
        wrappingLabelWithString:
            "Enter a Twitch client ID above or paste a token with the required scope."
    )

    init(settings: AppSettings, controller: TwitchNotificationController) {
        self.settings = settings
        self.controller = controller
        channelSelectionView = TwitchFollowedChannelSelectionView(settings: settings, controller: controller)
        super.init(frame: .zero)
        oauthClientIDField.stringValue = settings.twitchOAuthClientID
        translatesAutoresizingMaskIntoConstraints = false
        controller.onTokenSave = { [weak self] (success: Bool, savedToken: String) in
            guard let self else { return }
            if success,
               TwitchOAuthToken.normalized(self.tokenField.stringValue) == savedToken {
                self.tokenField.stringValue = ""
            }
            self.refresh()
        }
        buildView()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func refresh() {
        enabledSwitch.state = settings.twitchNotificationsEnabled ? .on : .off
        channelSelectionView.refresh()
        let tokenState = controller.oauthTokenState
        let hasStoredToken: Bool
        let storedTokenMessage: String
        switch tokenState {
        case .absent:
            hasStoredToken = false
            storedTokenMessage = "no oauth token saved"
        case .present:
            hasStoredToken = true
            storedTokenMessage = "oauth token saved securely in macos keychain"
        case .readFailure:
            hasStoredToken = false
            storedTokenMessage = "could not read oauth token from macos keychain"
        }
        tokenStatusLabel.stringValue = controller.isSavingOAuthToken
            ? "validating oauth token before replacing the saved token…"
            : storedTokenMessage
        let statusMessage = controller.displayedStatusMessage
        statusLabel.stringValue = "status: \(statusMessage)"
        let isNativeOAuthActive = controller.isAcquiringOAuthToken
        let isBrowserFallbackActive = controller.isAcquiringOAuthBrowserFallback
        let isOAuthActive = isNativeOAuthActive || isBrowserFallbackActive
        let isOAuthConfigured = TwitchOAuthConfiguration.isConfigured(
            TwitchOAuthConfiguration.resolvedClientID(userOverride: settings.twitchOAuthClientID)
        )
        updateOAuthClientIDControls()
        oauthConfigurationLabel.isHidden = isOAuthConfigured
        getOAuthTokenButton.title = isNativeOAuthActive ? "Cancel Twitch Sign-In" : "Get Token from Twitch"
        getOAuthTokenButton.isEnabled = isNativeOAuthActive
            || (isOAuthConfigured
                && !isBrowserFallbackActive
                && !controller.isSendingTestNotification
                && !controller.isSavingOAuthToken)
        browserFallbackButton.title = isBrowserFallbackActive ? "Cancel Browser Fallback" : "Use Browser Fallback"
        browserFallbackButton.isEnabled = isBrowserFallbackActive
            || (isOAuthConfigured
                && !isNativeOAuthActive
                && !controller.isSendingTestNotification
                && !controller.isSavingOAuthToken)
        tokenField.isEnabled = !isOAuthActive && !controller.isSavingOAuthToken
        saveTokenButton.isEnabled = !isOAuthActive
            && !controller.isSavingOAuthToken
            && !tokenField.stringValue.isEmpty
        removeTokenButton.isEnabled = !isOAuthActive && hasStoredToken
        testNotificationButton.isEnabled = !isOAuthActive
            && !controller.isSendingTestNotification
            && !controller.isSavingOAuthToken
        usernameField.isEnabled = !isOAuthActive
            && !controller.isSendingTestNotification
            && !controller.isSavingOAuthToken
    }

    private func buildView() {
        let titleLabel = makeTitleLabel()
        let detailLabel = makeDetailLabel()
        let enabledRow = makeEnabledRow()
        let clientIDRow = makeOAuthClientIDRow()
        let tokenRow = makeTokenRow()
        let oauthRow = makeOAuthRow()
        configureStatusLabels()
        let scopeLabel = makeScopeLabel()
        let avatarTestLabel = makeAvatarTestLabel()
        let avatarTestRow = makeAvatarTestRow()
        let stack = makeStack(
            views: [
                titleLabel,
                detailLabel,
                enabledRow,
                channelSelectionView,
                oauthClientIDHintLabel,
                clientIDRow,
                tokenRow,
                oauthConfigurationLabel,
                oauthRow,
                tokenStatusLabel,
                scopeLabel,
                avatarTestLabel,
                avatarTestRow,
                statusLabel
            ]
        )
        activateLayoutConstraints(
            stack: stack,
            detailLabel: detailLabel,
            scopeLabel: scopeLabel,
            avatarTestLabel: avatarTestLabel
        )
        NSLayoutConstraint.activate([
            channelSelectionView.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func toggleEnabled() {
        settings.twitchNotificationsEnabled = enabledSwitch.state == .on
        refresh()
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === oauthClientIDField {
            updateOAuthClientIDControls()
            return
        }
        saveTokenButton.isEnabled = !controller.isAcquiringOAuth
            && !controller.isSavingOAuthToken
            && !tokenField.stringValue.isEmpty
    }

    @objc private func saveOAuthClientID() {
        settings.twitchOAuthClientID = oauthClientIDField.stringValue
        oauthClientIDField.stringValue = settings.twitchOAuthClientID
        refresh()
    }

    @objc private func clearOAuthClientID() {
        settings.twitchOAuthClientID = ""
        oauthClientIDField.stringValue = ""
        refresh()
    }

    private func updateOAuthClientIDControls() {
        let canEdit = !controller.isAcquiringOAuth && !controller.isSavingOAuthToken
        let enteredClientID = oauthClientIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        oauthClientIDField.isEnabled = canEdit
        saveOAuthClientIDButton.isEnabled = canEdit && enteredClientID != settings.twitchOAuthClientID
        clearOAuthClientIDButton.isEnabled = canEdit && !settings.twitchOAuthClientID.isEmpty
    }
    @objc private func saveToken() {
        controller.saveOAuthToken(tokenField.stringValue)
        refresh()
    }

    @objc private func getOAuthToken() {
        if controller.isAcquiringOAuthToken {
            controller.cancelOAuthTokenAcquisition()
        } else {
            controller.startOAuthTokenAcquisition()
        }
    }

    @objc private func useBrowserFallback() {
        if controller.isAcquiringOAuthBrowserFallback {
            controller.cancelOAuthBrowserFallback()
        } else {
            controller.startOAuthBrowserFallback()
        }
    }

    @objc private func removeToken() {
        controller.removeOAuthToken()
        refresh()
    }

    @objc private func sendTestNotification() {
        controller.sendTestNotification(username: usernameField.stringValue)
        refresh()
    }
}

extension TwitchNotificationView {
    private func makeTitleLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "Twitch Notifications")
        label.font = .systemFont(ofSize: 20, weight: .semibold)
        return label
    }

    private func makeDetailLabel() -> NSTextField {
        let label = NSTextField(
            wrappingLabelWithString:
                "Notify through macos notification center when a channel followed by your Twitch account goes live. " +
                "This app never opens or plays streams."
        )
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeEnabledRow() -> NSStackView {
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleEnabled)
        let enabledLabel = NSTextField(labelWithString: "Enable notifications")
        let row = NSStackView(views: [enabledSwitch, enabledLabel])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func makeOAuthClientIDRow() -> NSStackView {
        oauthClientIDField.placeholderString = "Twitch OAuth client ID"
        oauthClientIDField.delegate = self
        oauthClientIDField.target = self
        oauthClientIDField.action = #selector(saveOAuthClientID)
        oauthClientIDField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        saveOAuthClientIDButton.target = self
        saveOAuthClientIDButton.action = #selector(saveOAuthClientID)
        clearOAuthClientIDButton.target = self
        clearOAuthClientIDButton.action = #selector(clearOAuthClientID)
        let row = NSStackView(views: [oauthClientIDField, saveOAuthClientIDButton, clearOAuthClientIDButton])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func makeTokenRow() -> NSStackView {
        tokenField.placeholderString = "paste Twitch OAuth access token"
        tokenField.isEditable = true
        tokenField.isSelectable = true
        tokenField.delegate = self
        tokenField.target = self
        tokenField.action = #selector(saveToken)
        tokenField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        saveTokenButton.target = self
        saveTokenButton.action = #selector(saveToken)
        removeTokenButton.target = self
        removeTokenButton.action = #selector(removeToken)
        let row = NSStackView(views: [tokenField, saveTokenButton, removeTokenButton])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func makeOAuthRow() -> NSStackView {
        getOAuthTokenButton.target = self
        getOAuthTokenButton.action = #selector(getOAuthToken)
        getOAuthTokenButton.toolTip = "Sign in to Twitch and save a token with the user:read:follows permission."
        browserFallbackButton.target = self
        browserFallbackButton.action = #selector(useBrowserFallback)
        browserFallbackButton.toolTip = "Open the legacy browser callback page if native Twitch sign-in does not work."
        let row = NSStackView(views: [getOAuthTokenButton, browserFallbackButton])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func configureStatusLabels() {
        tokenStatusLabel.textColor = .secondaryLabelColor
        tokenStatusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        oauthClientIDHintLabel.textColor = .secondaryLabelColor
        oauthClientIDHintLabel.font = .systemFont(ofSize: 12)
    }

    private func makeScopeLabel() -> NSTextField {
        let label = NSTextField(
            wrappingLabelWithString:
                "The token must include the user:read:follows scope. " +
                "An oauth: prefix is accepted and removed before storage."
        )
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        return label
    }

    private func makeAvatarTestLabel() -> NSTextField {
        let label = NSTextField(
            wrappingLabelWithString:
                "Enter a Twitch username to test its profile picture in the toast and notification. " +
                "Leave blank for a notification-only test."
        )
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        return label
    }

    private func makeAvatarTestRow() -> NSStackView {
        usernameField.placeholderString = "Twitch username"
        usernameField.delegate = self
        usernameField.target = self
        usernameField.action = #selector(sendTestNotification)
        usernameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        testNotificationButton.target = self
        testNotificationButton.action = #selector(sendTestNotification)
        let row = NSStackView(views: [usernameField, testNotificationButton])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func makeStack(views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        return stack
    }

    private func activateLayoutConstraints(
        stack: NSStackView,
        detailLabel: NSTextField,
        scopeLabel: NSTextField,
        avatarTestLabel: NSTextField
    ) {
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 260),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            tokenField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            usernameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            oauthClientIDField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            avatarTestLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            oauthClientIDHintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),

            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scopeLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
}
