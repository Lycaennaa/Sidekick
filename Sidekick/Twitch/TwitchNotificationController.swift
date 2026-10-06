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
    }

    static let keychainAccount = "twitch.oauth.access-token"

    private let settings: AppSettings
    private let notificationCenter: UNUserNotificationCenter?
    let tokenOwner: TwitchTokenOwner
    private let pollingOwner: TwitchPollingOwner
    private let deliveryOwner: TwitchDeliveryOwner
    private let testNotificationOwner: TwitchTestNotificationOwner
    private let oauthAuthorization: TwitchOAuthAuthorization
    private let oauthBrowserFallback: TwitchOAuthBrowserFallback
    private var terminating = false
    private var appliedTwitchNotificationsEnabled = false

    var status: Status = .disabled
    var onStateChange: (() -> Void)?
    var onStreamLive: ((TwitchFollowedStream, Data?) -> Void)?
    var onTestProfile: ((TwitchProfileTestPayload) -> Void)?
    var onStreamsLiveSummary: ((Int) -> Void)?
    var onOnlineStreamsChange: (([TwitchFollowedStream]) -> Void)?
    private(set) var onlineStreams: [TwitchFollowedStream] = []
    var onTokenSave: ((Bool, String) -> Void)?

    convenience init(
        settings: AppSettings,
        keychain: KeychainStore = KeychainStore(),
        apiClient: TwitchAPIClient = TwitchAPIClient(),
        notificationCenter: UNUserNotificationCenter = .current()
    ) {
        let notifications = TwitchNotificationCenterClient.live(notificationCenter)
        let tokenOwner = TwitchTokenOwner(
            dependencies: .init(
                read: { try keychain.read(account: Self.keychainAccount) },
                write: { try keychain.write($0, replacing: $1, account: Self.keychainAccount) },
                delete: { try keychain.delete(account: Self.keychainAccount) },
                authenticate: { token in
                    _ = try await apiClient.authenticate(accessToken: token)
                }
            )
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
        self.init(
            settings: settings,
            dependencies: .init(
                notificationCenter: notificationCenter,
                tokenOwner: tokenOwner,
                pollingOwner: pollingOwner,
                deliveryOwner: deliveryOwner,
                testNotificationOwner: testNotificationOwner
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
        self.oauthAuthorization = oauthAuthorization
        self.oauthBrowserFallback = oauthBrowserFallback
        super.init()
        self.notificationCenter?.delegate = self
    }

    var oauthTokenState: TwitchTokenOwner.StoredTokenState {
        tokenOwner.storedTokenState()
    }

    var tokenSaveErrorMessage: String? {
        tokenOwner.errorMessage
    }

    var testNotificationErrorMessage: String? {
        testNotificationOwner.errorMessage
    }

    func applySettings() {
        guard !terminating else { return }
        guard settings.twitchNotificationsEnabled else {
            testNotificationOwner.cancel()
            if appliedTwitchNotificationsEnabled {
                tokenOwner.cancel()
            }
            appliedTwitchNotificationsEnabled = false
            stopPolling()
            testNotificationOwner.clearError()
            setStatus(.disabled)
            return
        }

        appliedTwitchNotificationsEnabled = true
        guard !tokenOwner.isSaving else { return }
        let token: String
        switch tokenOwner.storedTokenState() {
        case .absent:
            stopPolling()
            setStatus(.needsOAuthToken)
            return
        case let .present(storedToken):
            token = storedToken
        case .readFailure:
            stopPolling()
            setStatus(.error("could not read oauth token from keychain"))
            return
        }

        if pollingOwner.token == token, pollingOwner.isRunning {
            return
        }
        if pollingOwner.token == token,
           !pollingOwner.isRunning,
           case let .polling(ownerStatus) = status,
           ownerStatus.isTerminal {
            return
        }
        startPolling(token: token)
    }

    @discardableResult
    func saveOAuthToken(_ rawToken: String) -> Bool {
        guard !oauthAuthorization.isActive, !oauthBrowserFallback.isActive else { return false }
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
        case let .saved(token, changed):
            if changed { testNotificationOwner.cancel() }
            if settings.twitchNotificationsEnabled, !pollingOwner.isRunning {
                startPolling(token: token)
            } else if !settings.twitchNotificationsEnabled {
                setStatus(.disabled)
            }
            onTokenSave?(true, token)
            return true
        case let .validating(_, changed):
            if changed { testNotificationOwner.cancel() }
            return true
        }
    }

    func removeOAuthToken() {
        guard !oauthAuthorization.isActive, !oauthBrowserFallback.isActive else { return }
        guard case .success = tokenOwner.remove() else {
            setStatus(.error("could not remove oauth token from keychain"))
            return
        }
        testNotificationOwner.cancel()
        stopPolling()
        setStatus(settings.twitchNotificationsEnabled ? .needsOAuthToken : .disabled)
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
            }
        )
        deliveryOwner.activate(generation: generation)
    }

    private func stopPolling() {
        pollingOwner.stop()
        deliveryOwner.cancel()
        setOnlineStreams([])
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
        case let .saved(token):
            onTokenSave?(true, token)
            stopPolling()
            applySettings()
        case let .failed(token, message):
            setStatus(.error(message), preservingTokenSaveError: true)
            onTokenSave?(false, token)
            guard settings.twitchNotificationsEnabled else { return }
            switch tokenOwner.storedTokenState() {
            case .present:
                applySettings()
            case .absent:
                return
            case .readFailure:
                setStatus(.error("could not read oauth token from keychain"))
            }
        }
    }

    private func setOnlineStreams(_ streams: [TwitchFollowedStream]) {
        guard onlineStreams != streams else { return }
        onlineStreams = streams
        onOnlineStreamsChange?(streams)
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

    private func handlePollingStreams(
        streams: [TwitchFollowedStream],
        session: TwitchAPIClient.Session,
        generation: UInt64
    ) async -> Set<String> {
        guard !terminating, settings.twitchNotificationsEnabled else { return [] }
        return await deliveryOwner.deliver(
            streams: streams,
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
