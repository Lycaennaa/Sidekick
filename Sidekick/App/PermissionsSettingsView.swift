import AppKit
import CoreGraphics
import UserNotifications

@MainActor
final class PermissionsSettingsView: NSView {
    private let notificationCenterClientOverride: TwitchNotificationCenterClient?
    private lazy var notificationCenterClient = notificationCenterClientOverride
        ?? TwitchNotificationCenterClient.live(.current())
    private lazy var notificationAuthorization = TwitchNotificationAuthorization(
        notifications: notificationCenterClient
    )
    private(set) var notificationRequestTask: Task<Void, Never>?
    private(set) var notificationRefreshTask: Task<Void, Never>?
    private let screenRecordingStatusLabel = NSTextField(labelWithString: "Checking…")
    private let screenRecordingDetailLabel = NSTextField(
        wrappingLabelWithString: "Screen Recording access is required to capture screenshots."
    )
    private let screenRecordingRequestButton = NSButton(title: "Request Access…", target: nil, action: nil)
    private let screenRecordingSettingsButton = NSButton(title: "Open System Settings…", target: nil, action: nil)
    private let notificationStatusLabel = NSTextField(labelWithString: "Checking…")
    private let notificationRequestButton = NSButton(title: "Request Permission…", target: nil, action: nil)
    private let notificationSettingsButton = NSButton(title: "Open System Settings…", target: nil, action: nil)
    private let notificationErrorLabel = NSTextField(wrappingLabelWithString: "")
    private let systemSettingsErrorLabel = NSTextField(wrappingLabelWithString: "")
    private var notificationAuthorizationStatus: UNAuthorizationStatus?
    private var notificationRequestInProgress = false
    private var notificationGeneration: UInt64 = 0

    init(notificationCenterClient: TwitchNotificationCenterClient? = nil) {
        self.notificationCenterClientOverride = notificationCenterClient
        super.init(frame: .zero)
        configureControls()
        buildInterface()
        updateNotificationStatus()
        updateScreenRecordingStatus()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        notificationRefreshTask?.cancel()
        notificationRequestTask?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func refresh() {
        updateScreenRecordingStatus()
        guard !notificationRequestInProgress else { return }
        notificationGeneration &+= 1
        let generation = notificationGeneration
        notificationRefreshTask?.cancel()
        let notificationCenterClient = notificationCenterClient
        notificationRefreshTask = Task { [weak self] in
            let status = await notificationCenterClient.authorizationStatus()
            guard let self,
                  !Task.isCancelled,
                  self.notificationGeneration == generation,
                  !self.notificationRequestInProgress else { return }
            self.notificationAuthorizationStatus = status
            self.notificationErrorLabel.stringValue = ""
            self.updateNotificationStatus()
        }
    }

    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        refresh()
    }

    @objc private func requestScreenRecordingAccess() {
        let isAllowed = CGRequestScreenCaptureAccess()
        updateScreenRecordingStatus()
        screenRecordingDetailLabel.stringValue = isAllowed
            ? "Access granted. macOS may require restarting Sidekick before screen capture works."
            : "Access is still off. If macOS has already asked, enable it in System Settings."
    }

    @objc private func openScreenRecordingSettings() {
        openSystemSettings(
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    @objc private func requestNotificationPermission() {
        guard !notificationRequestInProgress,
              notificationAuthorizationStatus == .notDetermined else { return }
        notificationRefreshTask?.cancel()
        notificationGeneration &+= 1
        let generation = notificationGeneration
        notificationRequestInProgress = true
        notificationErrorLabel.stringValue = ""
        updateNotificationStatus()
        let authorization = notificationAuthorization
        let notificationCenterClient = notificationCenterClient

        notificationRequestTask = Task { [weak self] in
            let result = await authorization.requestPermission { [weak self] in
                guard let self else { return false }
                return self.notificationGeneration == generation
                    && self.notificationRequestInProgress
            }
            guard self?.notificationGeneration == generation,
                  self?.notificationRequestInProgress == true else { return }
            if Task.isCancelled {
                guard let self,
                      self.notificationGeneration == generation,
                      self.notificationRequestInProgress else { return }
                self.notificationRequestInProgress = false
                self.notificationErrorLabel.stringValue = "Permission request cancelled."
                self.updateNotificationStatus()
                return
            }

            let status = await notificationCenterClient.authorizationStatus()
            guard let self,
                  self.notificationGeneration == generation,
                  self.notificationRequestInProgress else { return }
            let isCancelled = Task.isCancelled
            self.notificationRequestInProgress = false
            self.notificationAuthorizationStatus = status
            if isCancelled {
                self.notificationErrorLabel.stringValue = "Permission request cancelled."
            } else if result == .requestFailed {
                self.notificationErrorLabel.stringValue = "Request failed. Try again in System Settings."
            }
            self.updateNotificationStatus()
        }
    }

    @objc private func openNotificationSettings() {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        openSystemSettings(
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleIdentifier)"
        )
    }

    private func configureControls() {
        screenRecordingStatusLabel.identifier = NSUserInterfaceItemIdentifier("Permissions.ScreenRecording.Status")
        notificationStatusLabel.identifier = NSUserInterfaceItemIdentifier("Permissions.Notifications.Status")
        notificationErrorLabel.textColor = .systemRed
        notificationErrorLabel.isHidden = true
        systemSettingsErrorLabel.textColor = .systemRed
        systemSettingsErrorLabel.isHidden = true

        screenRecordingRequestButton.target = self
        screenRecordingRequestButton.action = #selector(requestScreenRecordingAccess)
        screenRecordingRequestButton.bezelStyle = .rounded
        screenRecordingRequestButton.identifier = NSUserInterfaceItemIdentifier("Permissions.ScreenRecording.Request")
        screenRecordingSettingsButton.target = self
        screenRecordingSettingsButton.action = #selector(openScreenRecordingSettings)
        screenRecordingSettingsButton.bezelStyle = .rounded
        screenRecordingSettingsButton.identifier = NSUserInterfaceItemIdentifier("Permissions.ScreenRecording.Settings")

        notificationRequestButton.target = self
        notificationRequestButton.action = #selector(requestNotificationPermission)
        notificationRequestButton.bezelStyle = .rounded
        notificationRequestButton.identifier = NSUserInterfaceItemIdentifier("Permissions.Notifications.Request")
        notificationSettingsButton.target = self
        notificationSettingsButton.action = #selector(openNotificationSettings)
        notificationSettingsButton.bezelStyle = .rounded
        notificationSettingsButton.identifier = NSUserInterfaceItemIdentifier("Permissions.Notifications.Settings")
    }

    private func buildInterface() {
        let heading = NSTextField(labelWithString: "Permissions")
        heading.font = .systemFont(ofSize: 26, weight: .semibold)
        let introduction = NSTextField(
            wrappingLabelWithString: "Sidekick needs these macOS permissions for screenshots and Twitch alerts."
        )
        let microphoneNote = NSTextField(
            wrappingLabelWithString: """
                Sidekick does not record microphone audio. Its microphone activity indicator reads CoreAudio
                activity state and does not require microphone access.
                """
        )
        microphoneNote.textColor = .secondaryLabelColor

        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [
            heading,
            introduction,
            makePermissionSection(
                title: "Screen Recording",
                detail: screenRecordingDetailLabel,
                status: screenRecordingStatusLabel,
                buttons: [screenRecordingRequestButton, screenRecordingSettingsButton]
            ),
            separator,
            makePermissionSection(
                title: "Notifications",
                detail: NSTextField(
                    wrappingLabelWithString: "Used for Twitch alerts. Manage this in System Settings."
                ),
                status: notificationStatusLabel,
                buttons: [notificationRequestButton, notificationSettingsButton],
                extraContent: notificationErrorLabel
            ),
            microphoneNote,
            systemSettingsErrorLabel
        ])
        stack.orientation = .vertical
        stack.spacing = 18
        configureSettingsPageStack(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
    }

    private func makePermissionSection(
        title: String,
        detail: NSTextField,
        status: NSTextField,
        buttons: [NSButton],
        extraContent: NSView? = nil
    ) -> NSStackView {
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        status.font = .systemFont(ofSize: 13, weight: .medium)

        let statusAndActions = NSStackView(views: [status] + buttons)
        statusAndActions.orientation = .horizontal
        statusAndActions.alignment = .centerY
        statusAndActions.distribution = .fill
        statusAndActions.spacing = 8

        var rows: [NSView] = [heading, detail, statusAndActions]
        if let extraContent {
            rows.append(extraContent)
        }
        let section = NSStackView(views: rows)
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        for row in section.arrangedSubviews {
            row.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        }
        return section
    }

    private func updateScreenRecordingStatus() {
        let isAllowed = CGPreflightScreenCaptureAccess()
        screenRecordingStatusLabel.stringValue = isAllowed ? "Allowed" : "Not Allowed"
        screenRecordingRequestButton.isEnabled = !isAllowed
        if isAllowed {
            screenRecordingDetailLabel.stringValue = "Access is enabled for screenshot capture."
        }
    }

    private func updateNotificationStatus() {
        if notificationRequestInProgress {
            notificationStatusLabel.stringValue = "Waiting for macOS…"
        } else if let notificationAuthorizationStatus {
            notificationStatusLabel.stringValue = Self.description(for: notificationAuthorizationStatus)
        } else {
            notificationStatusLabel.stringValue = "Checking…"
        }
        notificationRequestButton.isEnabled = !notificationRequestInProgress
            && notificationAuthorizationStatus == .notDetermined
        notificationErrorLabel.isHidden = notificationErrorLabel.stringValue.isEmpty
    }

    private func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString), NSWorkspace.shared.open(url) else {
            systemSettingsErrorLabel.stringValue =
                "Could not open System Settings. Open it manually to change Sidekick’s permission."
            systemSettingsErrorLabel.isHidden = false
            return
        }
        systemSettingsErrorLabel.stringValue = ""
        systemSettingsErrorLabel.isHidden = true
    }

    private static func description(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            "Not Requested"
        case .denied:
            "Not Allowed"
        case .authorized, .provisional, .ephemeral:
            "Allowed"
        @unknown default:
            "Unknown"
        }
    }
}
