import AppKit
import UserNotifications

@MainActor
final class TwitchNotificationController: NSObject, UNUserNotificationCenterDelegate {
    enum Status: Equatable {
        case disabled
        case needsOAuthToken
        case polling(TwitchPollingOwner.Status)
        case error(String)

        var message: String {
            switch self {
            case .disabled:
                "disabled"
            case .needsOAuthToken:
                "add an oauth token to begin"
            case let .polling(status):
                status.message
            case let .error(message):
                message
            }
        }
    }

    struct Dependencies {
        let notificationCenter: UNUserNotificationCenter?
        let tokenOwner: TwitchTokenOwner
        let pollingOwner: TwitchPollingOwner
        let deliveryOwner: TwitchDeliveryOwner
        let testNotificationOwner: TwitchTestNotificationOwner
        let keychainAccessPromptOwner: TwitchKeychainAccessPromptOwner
    }

    static let keychainAccount = "twitch.oauth.access-token"

    let settings: AppSettings
    private let notificationCenter: UNUserNotificationCenter?
    let tokenOwner: TwitchTokenOwner
    private let pollingOwner: TwitchPollingOwner
    private let deliveryOwner: TwitchDeliveryOwner
    let testNotificationOwner: TwitchTestNotificationOwner
    private let oauthAuthorization: TwitchOAuthAuthorization
    private let oauthBrowserFallback: TwitchOAuthBrowserFallback
    let keychainAccessPromptOwner: TwitchKeychainAccessPromptOwner
    var pendingOAuthTokenSave: String?
    var terminating = false
    private var appliedTwitchNotificationsEnabled = false

    var status: Status = .disabled
    var onStateChange: (() -> Void)?
    var onStreamLive: ((TwitchFollowedStream, Data?) -> Void)?
    var onTestProfile: ((TwitchProfileTestPayload) -> Void)?
    var onStreamsLiveSummary: ((Int) -> Void)?
    var onOnlineStreamsChange: (([TwitchFollowedStream]) -> Void)?
    private(set) var onlineStreams: [TwitchFollowedStream] = []
    private var followedChannelDirectory = TwitchFollowedChannelDirectory()
    var followedChannels: [TwitchFollowedChannel] { followedChannelDirectory.channels }
    var hasLoadedFollowedChannels: Bool { followedChannelDirectory.hasLoaded }
    var followedChannelsLoadFailed: Bool { followedChannelDirectory.hasFailed }
    var onTokenSave: ((Bool, String) -> Void)?

    convenience init(
        settings: AppSettings,
        keychain: KeychainStore = KeychainStore(),
        apiClient: TwitchAPIClient = TwitchAPIClient(),
        notificationCenter: UNUserNotificationCenter = .current()
    ) {
        let notifications = TwitchNotificationCenterClient.live(notificationCenter)
        let tokenOwner = Self.makeLiveTokenOwner(
            keychain: keychain,
            apiClient: apiClient,
            account: Self.keychainAccount
        )
        let notificationScheduler = TwitchNotificationScheduler(
            notifications: notifications,
            sleeper: .live,
            cleanupInterval: 2
        )
        let pollingOwner = TwitchPollingOwner(
            dependencies: .init(
                authenticate: { try await apiClient.authenticate(accessToken: $0) },
                followedStreams: { try await apiClient.followedStreams(for: $0) },
                followedChannels: { try await apiClient.followedChannels(for: $0) },
                notifications: notifications,
                sleeper: .live,
                pollInterval: TwitchAPIClient.pollInterval
            )
        )
        let deliveryOwner = TwitchDeliveryOwner(
            dependencies: .init(
                profileImages: { apiClient.profileImageResults(for: $0, session: $1) },
                notifications: notifications,
                sleeper: .live,
                cleanupInterval: 2
            ),
            scheduler: notificationScheduler
        )
        let testNotificationOwner = TwitchTestNotificationOwner(
            dependencies: .init(
                storedTokenState: { tokenOwner.storedTokenState() },
                authenticate: { try await apiClient.authenticate(accessToken: $0) },
                profileImage: { try await apiClient.profileImageData(forUsername: $0, session: $1) },
                notifications: notifications
            ),
            scheduler: notificationScheduler
        )
        let keychainAccessPromptOwner = TwitchKeychainAccessPromptOwner(
            request: { try await keychain.promptForAccess(account: Self.keychainAccount) }
        )
        self.init(
            settings: settings,
            dependencies: .init(
                notificationCenter: notificationCenter,
                tokenOwner: tokenOwner,
                pollingOwner: pollingOwner,
                deliveryOwner: deliveryOwner,
                testNotificationOwner: testNotificationOwner,
                keychainAccessPromptOwner: keychainAccessPromptOwner
            )
        )
    }

    init(
        settings: AppSettings,
        dependencies: Dependencies,
        oauthAuthorization: TwitchOAuthAuthorization = TwitchOAuthAuthorization(),
        oauthBrowserFallback: TwitchOAuthBrowserFallback = TwitchOAuthBrowserFallback()
    ) {
        self.settings = settings
        notificationCenter = dependencies.notificationCenter
        tokenOwner = dependencies.tokenOwner
        pollingOwner = dependencies.pollingOwner
        deliveryOwner = dependencies.deliveryOwner
        testNotificationOwner = dependencies.testNotificationOwner
        keychainAccessPromptOwner = dependencies.keychainAccessPromptOwner
        self.oauthAuthorization = oauthAuthorization
        self.oauthBrowserFallback = oauthBrowserFallback
        super.init()
        self.notificationCenter?.delegate = self
    }

    func applySettings() {
        guard shouldApplyTwitchSettings() else { return }
        let tokenState = tokenOwner.storedTokenState()
        if case .loading = tokenState {
            refreshStoredKeychainTokenState()
        } else {
            applyStoredTokenState(tokenState)
        }
    }

    func applySettings(storedTokenState: TwitchTokenOwner.StoredTokenState) {
        guard shouldApplyTwitchSettings() else { return }
        applyStoredTokenState(storedTokenState)
    }

    private func shouldApplyTwitchSettings() -> Bool {
        guard !terminating else { return false }
        guard settings.twitchNotificationsEnabled else {
            testNotificationOwner.cancel()
            if appliedTwitchNotificationsEnabled {
                tokenOwner.cancel()
            }
            appliedTwitchNotificationsEnabled = false
            stopPolling()
            testNotificationOwner.clearError()
            setStatus(.disabled)
            return false
        }
        appliedTwitchNotificationsEnabled = true
        return !tokenOwner.isSaving && !keychainAccessPromptOwner.isRequesting
    }

    private func applyStoredTokenState(_ state: TwitchTokenOwner.StoredTokenState) {
        switch state {
        case .loading:
            return
        case .absent:
            stopPolling()
            setStatus(.needsOAuthToken)
        case let .present(token):
            if pollingOwner.token == token {
                guard !pollingOwner.isRunning else { return }
                guard !isTerminalPollingStatus else { return }
            }
            startPolling(token: token)
        case .readFailure:
            stopPolling()
            setStatus(.error("could not read oauth token from keychain"))
        }
    }

    private var isTerminalPollingStatus: Bool {
        guard case let .polling(ownerStatus) = status else { return false }
        return ownerStatus.isTerminal
    }

    @discardableResult
    func saveOAuthToken(_ rawToken: String) -> Bool {
        guard !oauthAuthorization.isActive, !oauthBrowserFallback.isActive else { return false }
        if keychainAccessPromptOwner.isRequesting {
            guard pendingOAuthTokenSave == nil else { return false }
            pendingOAuthTokenSave = rawToken
            return true
        }
        let result = tokenOwner.save(
            rawToken,
            notificationsEnabled: settings.twitchNotificationsEnabled
        ) { [weak self] event in
            self?.handleTokenEvent(event)
        }
        switch result {
        case let .rejected(token, message):
            setStatus(.error(message))
            onTokenSave?(false, token)
            return false
        case .validating:
            return true
        }
    }

    func removeOAuthToken() {
        guard !oauthAuthorization.isActive,
              !oauthBrowserFallback.isActive,
              !keychainAccessPromptOwner.isRequesting else { return }
        tokenOwner.remove { [weak self] result in
            guard let self, !self.terminating else { return }
            switch result {
            case .success:
                testNotificationOwner.cancel()
                stopPolling()
                setStatus(settings.twitchNotificationsEnabled ? .needsOAuthToken : .disabled)
            case .failure:
                setStatus(.error("could not remove oauth token from keychain"))
                tokenOwner.refreshStoredTokenState { [weak self] state in
                    guard let self, !self.terminating else { return }
                    if self.settings.twitchNotificationsEnabled {
                        self.applySettings(storedTokenState: state)
                    }
                    self.onStateChange?()
                }
            }
            onStateChange?()
        }
    }

    func sendTestNotification(username: String? = nil) {
        guard !terminating, !oauthAuthorization.isActive, !oauthBrowserFallback.isActive else { return }
        testNotificationOwner.send(
            username: username,
            tokenSaveInProgress: tokenOwner.isSaving
        ) { [weak self] event in
            guard let self else { return }
            if case let .profileTest(payload) = event {
                onTestProfile?(payload)
            }
            onStateChange?()
        }
    }

    func retryAuthorizationIfNeeded() {
        guard settings.twitchNotificationsEnabled,
              status == .polling(.notificationPermissionDenied)
                || status == .polling(.notificationPermissionError) else {
            return
        }
        stopPolling()
        applySettings()
    }

    func terminate() {
        guard !terminating else { return }
        terminating = true
        pendingOAuthTokenSave = nil
        keychainAccessPromptOwner.terminate()
        oauthAuthorization.cancel()
        oauthBrowserFallback.cancel()
        tokenOwner.cancel()
        testNotificationOwner.cancel()
        stopPolling()
        notificationCenter?.delegate = nil
    }

    private func startPolling(token: String) {
        stopPolling()
        let generation = pollingOwner.start(
            token: token,
            onStatusWithGeneration: { [weak self] status, generation in
                self?.handlePollingStatus(status, generation: generation)
            },
            onStreams: { [weak self] streams, session, generation in
                await self?.handlePollingStreams(
                    streams: streams,
                    session: session,
                    generation: generation
                ) ?? []
            },
            onCurrentStreams: { [weak self] streams, generation in
                self?.handleCurrentStreams(streams, generation: generation)
            },
            onFollowedChannels: { [weak self] channels, generation in
                self?.handleFollowedChannels(channels, generation: generation)
            }
        )
        deliveryOwner.activate(generation: generation)
    }

    private func stopPolling() {
        pollingOwner.stop()
        deliveryOwner.cancel()
        setOnlineStreams([])
        clearFollowedChannels()
    }

    private func handleOAuthAuthorizationResult(
        _ result: Result<String, TwitchOAuthAuthorization.AuthorizationError>
    ) {
        guard !terminating else { return }
        switch result {
        case let .success(token):
            testNotificationOwner.clearError()
            let previousStatus = status
            _ = saveOAuthToken(token)
            if status == previousStatus { onStateChange?() }
        case .failure(.cancelled):
            onStateChange?()
        case let .failure(error):
            let previousStatus = status
            setStatus(.error(error.localizedDescription))
            if status == previousStatus { onStateChange?() }
        }
    }

    private func handleTokenEvent(_ event: TwitchTokenOwner.Event) {
        switch event {
        case let .saved(token, changed):
            onTokenSave?(true, token)
            if changed {
                testNotificationOwner.cancel()
                stopPolling()
            }
            applySettings(storedTokenState: .present(token))
        case let .failed(token, message):
            setStatus(.error(message), preservingTokenSaveError: true)
            onTokenSave?(false, token)
            if settings.twitchNotificationsEnabled {
                applySettings()
            }
        }
    }

    private func setOnlineStreams(_ streams: [TwitchFollowedStream]) {
        guard onlineStreams != streams else { return }
        onlineStreams = streams
        onOnlineStreamsChange?(streams)
    }

    private func clearFollowedChannels() {
        guard followedChannelDirectory.reset() else { return }
        onStateChange?()
    }

}
private extension TwitchNotificationController {
    private func handlePollingStatus(
        _ ownerStatus: TwitchPollingOwner.Status,
        generation: UInt64
    ) {
        guard !terminating,
              settings.twitchNotificationsEnabled,
              pollingOwner.isCurrent(generation) else { return }
        setStatus(.polling(ownerStatus))
        if ownerStatus.isTerminal {
            setOnlineStreams([])
        }
    }

    private func handleCurrentStreams(
        _ streams: [TwitchFollowedStream],
        generation: UInt64
    ) {
        guard !terminating,
              settings.twitchNotificationsEnabled,
              pollingOwner.isCurrent(generation) else { return }
        setOnlineStreams(streams)
    }

    private func handleFollowedChannels(
        _ channels: [TwitchFollowedChannel]?,
        generation: UInt64
    ) {
        guard !terminating,
              settings.twitchNotificationsEnabled,
              pollingOwner.isCurrent(generation),
              followedChannelDirectory.update(channels) else { return }
        if let channels {
            settings.pruneTwitchChannelSelections(keeping: Set(channels.map(\.id)))
        }
        onStateChange?()
    }

    private func handlePollingStreams(
        streams: [TwitchFollowedStream],
        session: TwitchAPIClient.Session,
        generation: UInt64
    ) async -> Set<String> {
        guard !terminating, settings.twitchNotificationsEnabled else { return [] }
        let mode = settings.twitchNotificationChannelMode
        let selectedChannelIDs = settings.twitchSelectedChannelIDs(for: mode)
        let filteredStreams = streams.filter {
            mode.includes(channelID: $0.userID, selectedChannelIDs: selectedChannelIDs)
        }
        return await deliveryOwner.deliver(
            streams: filteredStreams,
            session: session,
            generation: generation
        ) { [weak self] event in
            self?.handleDeliveryEvent(event)
        }
    }

    private func handleDeliveryEvent(_ event: TwitchDeliveryOwner.Event) {
        switch event {
        case let .streamDelivered(stream, imageData):
            onStreamLive?(stream, imageData)
        case let .summaryDelivered(count):
            onStreamsLiveSummary?(count)
        case .schedulingFailed:
            setStatus(.error("could not schedule a twitch notification"))
        }
    }
}

extension TwitchNotificationController {
    var displayedStatusMessage: String {
        if case .error = status {
            return status.message
        }
        return testNotificationErrorMessage
            ?? tokenSaveErrorMessage
            ?? status.message
    }

    var isSavingOAuthToken: Bool {
        tokenOwner.isSaving
    }

    var isSendingTestNotification: Bool {
        testNotificationOwner.isSending
    }

    var isAcquiringOAuthToken: Bool {
        oauthAuthorization.isActive
    }

    var isAcquiringOAuthBrowserFallback: Bool {
        oauthBrowserFallback.isActive
    }

    var isAcquiringOAuth: Bool {
        isAcquiringOAuthToken || isAcquiringOAuthBrowserFallback
    }

    func startOAuthTokenAcquisition() {
        guard !terminating, !oauthBrowserFallback.isActive else { return }
        tokenOwner.cancel()
        testNotificationOwner.cancel()
        tokenOwner.clearError()
        testNotificationOwner.clearError()
        let clientID = TwitchOAuthConfiguration.resolvedClientID(userOverride: settings.twitchOAuthClientID)
        let started = oauthAuthorization.start(clientID: clientID) { [weak self] result in
            self?.handleOAuthAuthorizationResult(result)
        }
        if started { onStateChange?() }
    }

    func cancelOAuthTokenAcquisition() {
        guard oauthAuthorization.isActive else { return }
        oauthAuthorization.cancel()
    }

    func startOAuthBrowserFallback() {
        guard !terminating, !oauthAuthorization.isActive else { return }
        tokenOwner.cancel()
        testNotificationOwner.cancel()
        tokenOwner.clearError()
        testNotificationOwner.clearError()
        let clientID = TwitchOAuthConfiguration.resolvedClientID(userOverride: settings.twitchOAuthClientID)
        let started = oauthBrowserFallback.start(clientID: clientID) { [weak self] result in
            self?.handleOAuthAuthorizationResult(result)
        }
        if started { onStateChange?() }
    }

    func cancelOAuthBrowserFallback() {
        guard oauthBrowserFallback.isActive else { return }
        oauthBrowserFallback.cancel()
    }
}
