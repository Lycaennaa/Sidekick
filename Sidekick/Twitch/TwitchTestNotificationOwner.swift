import Foundation
import UserNotifications

@MainActor
final class TwitchTestNotificationOwner {
    struct Dependencies: Sendable {
        let storedTokenState: @MainActor @Sendable () -> TwitchTokenOwner.StoredTokenState
        let authenticate: @Sendable (String) async throws -> TwitchAPIClient.Session
        let profileImage: @Sendable (
            String,
            TwitchAPIClient.Session
        ) async throws -> (profile: TwitchUserProfile, imageData: Data?)
        let notifications: TwitchNotificationCenterClient
    }

    enum Event: Sendable {
        case started
        case profileTest(TwitchProfileTestPayload)
        case finished
        case failed
        case cancelled
        case rejected
    }

    private enum OwnerError: Error {
        case missingOAuthToken
        case keychain
    }
    private struct Operation: Sendable {
        let generation: UInt64
        let onEvent: @MainActor @Sendable (Event) -> Void
    }

    private var activeOperation: Operation?

    private let dependencies: Dependencies
    private let authorization: TwitchNotificationAuthorization
    private let scheduler: TwitchNotificationScheduler
    private let scope: TwitchNotificationScheduler.Scope
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lastIdentifier: String?
    private(set) var errorMessage: String?

    init(
        dependencies: Dependencies,
        scheduler: TwitchNotificationScheduler? = nil
    ) {
        self.dependencies = dependencies
        authorization = TwitchNotificationAuthorization(notifications: dependencies.notifications)
        let scheduler = scheduler ?? TwitchNotificationScheduler(notifications: dependencies.notifications)
        self.scheduler = scheduler
        scope = scheduler.makeScope()
    }

    var isSending: Bool {
        task != nil
    }

    func send(
        username rawUsername: String?,
        tokenSaveInProgress: Bool,
        onEvent: @escaping @MainActor @Sendable (Event) -> Void
    ) {
        guard task == nil else { return }

        let username: String?
        if let rawUsername,
           !rawUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = TwitchUsername.normalized(rawUsername)
            guard !normalized.isEmpty else {
                errorMessage = "enter a valid twitch username"
                onEvent(.rejected)
                return
            }
            username = normalized
        } else {
            username = nil
        }

        guard username == nil || !tokenSaveInProgress else {
            errorMessage = "wait for oauth token validation to finish"
            onEvent(.rejected)
            return
        }

        if let lastIdentifier {
            scheduler.removeScheduledNotification(
                identifier: lastIdentifier,
                scope: scope
            )
        }
        errorMessage = nil
        generation &+= 1
        let requestedGeneration = generation
        scheduler.activate(generation: requestedGeneration, scope: scope)
        let operation = Operation(generation: requestedGeneration, onEvent: onEvent)
        activeOperation = operation
        task = Task { [weak self, operation] in
            guard let self else { return }
            let terminalEvent = await self.perform(
                username: username,
                generation: requestedGeneration,
                operation: operation
            )
            guard self.activeOperation?.generation == operation.generation else { return }
            self.task = nil
            self.activeOperation = nil
            operation.onEvent(terminalEvent)
        }
        onEvent(.started)
    }

    func cancel() {
        let operation = activeOperation
        task?.cancel()
        task = nil
        activeOperation = nil
        generation &+= 1
        scheduler.cancel(scope: scope)
        operation?.onEvent(.cancelled)
    }

    func clearError() {
        errorMessage = nil
    }

    private func makeProfileTest(
        username: String,
        generation: UInt64
    ) async throws -> TwitchProfileTestPayload {
        let token: String
        switch dependencies.storedTokenState() {
        case .absent:
            throw OwnerError.missingOAuthToken
        case let .present(storedToken):
            guard !storedToken.isEmpty else {
                throw OwnerError.missingOAuthToken
            }
            token = storedToken
        case .readFailure:
            throw OwnerError.keychain
        }

        let session = try await dependencies.authenticate(token)
        guard isCurrent(generation) else { throw CancellationError() }
        let result = try await dependencies.profileImage(username, session)
        guard isCurrent(generation) else { throw CancellationError() }
        let userLogin = result.profile.login.flatMap { $0.isEmpty ? nil : $0 } ?? username
        let displayName = result.profile.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? userLogin
        return TwitchProfileTestPayload(
            userID: result.profile.id,
            userLogin: userLogin,
            displayName: displayName,
            imageData: result.imageData
        )
    }

    private func isCurrent(_ requestedGeneration: UInt64) -> Bool {
        !Task.isCancelled && generation == requestedGeneration && task != nil
    }

    private func failureMessage(for error: Error) -> String {
        if let error = error as? OwnerError {
            switch error {
            case .missingOAuthToken:
                return "save an oauth token before testing a twitch avatar"
            case .keychain:
                return "could not read oauth token from keychain"
            }
        }
        if let error = error as? TwitchAPIClient.APIError {
            switch error {
            case .invalidToken:
                return "oauth token is invalid or expired"
            case .missingFollowedStreamsScope:
                return "token needs user:read:follows permission"
            case .userNotFound:
                return "twitch username was not found"
            case .network:
                return "could not reach twitch"
            case .rateLimited:
                return "twitch api rate limit reached"
            case .server, .invalidResponse, .tooManyFollowedStreams, .tooManyProfileImages:
                return "could not fetch twitch profile picture"
            }
        }
        return "could not fetch twitch profile picture"
    }
}
extension TwitchTestNotificationOwner {
    private func perform(
        username: String?,
        generation: UInt64,
        operation: Operation
    ) async -> Event {
        do {
            let notification = try await makeNotificationContent(
                username: username,
                generation: generation
            )
            guard isCurrent(generation) else { return .finished }
            if let terminalEvent = await permissionTerminalEvent(generation: generation) {
                return terminalEvent
            }
            guard isCurrent(generation) else { return .finished }
            return await schedule(
                notification: notification,
                generation: generation,
                operation: operation
            )
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard isCurrent(generation) else { return .finished }
            errorMessage = failureMessage(for: error)
            return .failed
        }
    }

    private func makeNotificationContent(
        username: String?,
        generation: UInt64
    ) async throws -> (content: UNNotificationContent, profileTest: TwitchProfileTestPayload?) {
        guard let username else {
            return (TwitchNotificationContent.test(), nil)
        }
        let profileTest = try await makeProfileTest(
            username: username,
            generation: generation
        )
        guard isCurrent(generation) else { throw CancellationError() }
        if profileTest.imageData == nil {
            errorMessage = "twitch profile found, but its profile picture could not be fetched"
        }
        let content = TwitchNotificationContent.withProfileImage(
            TwitchNotificationContent.profileTest(for: profileTest),
            profileTest: profileTest
        ).content
        return (content, profileTest)
    }

    private func permissionTerminalEvent(generation: UInt64) async -> Event? {
        let permission = await authorization.requestPermission { [weak self] in
            self?.isCurrent(generation) == true
        }
        guard isCurrent(generation) else { return .finished }
        switch permission {
        case .granted:
            return nil
        case .denied:
            errorMessage = "macos notifications are denied for this app"
            return .failed
        case .requestFailed:
            errorMessage = "could not request macos notification permission"
            return .failed
        }
    }

    private func schedule(
        notification: (content: UNNotificationContent, profileTest: TwitchProfileTestPayload?),
        generation: UInt64,
        operation: Operation
    ) async -> Event {
        let identifier = "twitch-test-notification-\(generation)"
        lastIdentifier = identifier
        let scheduled = await scheduler.schedule(
            identifier: identifier,
            content: notification.content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false),
            generation: generation,
            scope: scope
        )
        guard scheduled else {
            guard isCurrent(generation) else { return .finished }
            errorMessage = "could not schedule a test twitch notification"
            return .failed
        }
        guard isCurrent(generation) else {
            scheduler.removeScheduledNotification(
                identifier: identifier,
                scope: scope
            )
            return .finished
        }
        if let profileTest = notification.profileTest {
            operation.onEvent(.profileTest(profileTest))
        }
        return .finished
    }
}
