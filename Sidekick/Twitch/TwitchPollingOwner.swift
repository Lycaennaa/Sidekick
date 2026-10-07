import Foundation
import UserNotifications

@MainActor
final class TwitchPollingOwner {
    struct Dependencies: Sendable {
        let authenticate: @Sendable (String) async throws -> TwitchAPIClient.Session
        let followedStreams: @Sendable (TwitchAPIClient.Session) async throws -> [TwitchFollowedStream]
        let followedChannels: @Sendable (TwitchAPIClient.Session) async throws -> [TwitchFollowedChannel]
        let notifications: TwitchNotificationCenterClient
        let sleeper: TwitchSleepClient
        let pollInterval: TimeInterval
    }

    enum Status: Equatable, Sendable {
        case requestingPermission
        case checking
        case active
        case notificationPermissionDenied
        case notificationPermissionError
        case invalidOAuthToken
        case missingFollowedStreamsScope
        case error(String)

        var isTerminal: Bool {
            switch self {
            case .notificationPermissionDenied, .invalidOAuthToken, .missingFollowedStreamsScope:
                true
            default:
                false
            }
        }

        var message: String {
            switch self {
            case .requestingPermission:
                "requesting notification permission…"
            case .checking:
                "checking twitch…"
            case .active:
                "watching followed channels · checks every \(TwitchAPIClient.pollInterval.formatted()) seconds"
            case .notificationPermissionDenied:
                "macos notifications are denied for this app"
            case .invalidOAuthToken:
                "oauth token is invalid or expired"
            case .missingFollowedStreamsScope:
                "token needs user:read:follows permission"
            case .notificationPermissionError:
                "could not request macos notification permission; retrying"
            case let .error(message):
                message
            }
        }
    }

    typealias StatusHandler = @MainActor @Sendable (Status) -> Void
    typealias GenerationStatusHandler = @MainActor @Sendable (Status, UInt64) -> Void
    typealias CurrentStreamsHandler = @MainActor @Sendable ([TwitchFollowedStream], UInt64) -> Void
    typealias FollowedChannelsHandler = @MainActor @Sendable ([TwitchFollowedChannel]?, UInt64) -> Void
    typealias StreamsHandler = @MainActor @Sendable (
        [TwitchFollowedStream],
        TwitchAPIClient.Session,
        UInt64
    ) async -> Set<String>
    private struct Callbacks: Sendable {
        let onStatus: GenerationStatusHandler
        let onStreams: StreamsHandler
        let onCurrentStreams: CurrentStreamsHandler?
        let onFollowedChannels: FollowedChannelsHandler?
    }

    private enum StreamBaseline {
        case awaitingFirstFetch
        case recoveringFromOffline
        case known(Set<String>)

        func streamsToNotify(
            currentStreams: [TwitchFollowedStream]
        ) -> [TwitchFollowedStream] {
            switch self {
            case .awaitingFirstFetch:
                return []
            case .recoveringFromOffline:
                return currentStreams
            case let .known(previousStreamIDs):
                return TwitchNotificationState.newlyLiveStreams(
                    currentStreams: currentStreams,
                    previousStreamIDs: previousStreamIDs
                )
            }
        }

        func afterSuccessfulFetch(
            _ streams: [TwitchFollowedStream]
        ) -> Self {
            .known(Set(streams.map(\.id)))
        }

        func afterDeliveryFailure(_ failedIDs: Set<String>) -> Self {
            guard case let .known(streamIDs) = self else { return self }
            return .known(streamIDs.subtracting(failedIDs))
        }

        func afterNetworkFailure() -> Self {
            guard case .awaitingFirstFetch = self else { return self }
            return .recoveringFromOffline
        }
    }

    private let dependencies: Dependencies
    private let authorization: TwitchNotificationAuthorization
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var streamBaseline: StreamBaseline = .awaitingFirstFetch
    private(set) var token: String?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        authorization = TwitchNotificationAuthorization(notifications: dependencies.notifications)
    }

    var isRunning: Bool {
        task != nil
    }

    @discardableResult
    func start(
        token: String,
        onStatus: @escaping StatusHandler,
        onStreams: @escaping StreamsHandler,
        onCurrentStreams: CurrentStreamsHandler? = nil,
        onFollowedChannels: FollowedChannelsHandler? = nil
    ) -> UInt64 {
        start(
            token: token,
            onStatusWithGeneration: { status, _ in onStatus(status) },
            onStreams: onStreams,
            onCurrentStreams: onCurrentStreams,
            onFollowedChannels: onFollowedChannels
        )
    }

    @discardableResult
    func start(
        token: String,
        onStatusWithGeneration: @escaping GenerationStatusHandler,
        onStreams: @escaping StreamsHandler,
        onCurrentStreams: CurrentStreamsHandler? = nil,
        onFollowedChannels: FollowedChannelsHandler? = nil
    ) -> UInt64 {
        stop()
        generation &+= 1
        let requestedGeneration = generation
        self.token = token
        streamBaseline = .awaitingFirstFetch
        let callbacks = Callbacks(
            onStatus: onStatusWithGeneration,
            onStreams: onStreams,
            onCurrentStreams: onCurrentStreams,
            onFollowedChannels: onFollowedChannels
        )
        task = Task { [weak self] in
            await self?.run(token: token, generation: requestedGeneration, callbacks: callbacks)
        }
        return requestedGeneration
    }

    func stop() {
        task?.cancel()
        task = nil
        generation &+= 1
        token = nil
        streamBaseline = .awaitingFirstFetch
    }

    private func run(token: String, generation: UInt64, callbacks: Callbacks) async {
        defer {
            if self.generation == generation {
                task = nil
            }
        }

        guard isCurrent(generation) else { return }
        callbacks.onStatus(.requestingPermission, generation)
        guard await waitForPermission(generation: generation, onStatus: callbacks.onStatus) else { return }
        await poll(token: token, generation: generation, callbacks: callbacks)
    }

    func isCurrent(_ requestedGeneration: UInt64) -> Bool {
        !Task.isCancelled && generation == requestedGeneration && task != nil
    }
}
extension TwitchPollingOwner {
    private func waitForPermission(
        generation: UInt64,
        onStatus: @escaping GenerationStatusHandler
    ) async -> Bool {
        while isCurrent(generation) {
            let permissionResult = await authorization.requestPermission { [weak self] in
                self?.isCurrent(generation) == true
            }
            guard isCurrent(generation) else { return false }
            switch permissionResult {
            case .granted:
                return true
            case .denied:
                onStatus(.notificationPermissionDenied, generation)
                return false
            case .requestFailed:
                onStatus(.notificationPermissionError, generation)
                do {
                    try await dependencies.sleeper.sleep(dependencies.pollInterval)
                } catch {
                    return false
                }
            }
        }
        return false
    }

    private func poll(token: String, generation: UInt64, callbacks: Callbacks) async {
        while isCurrent(generation) {
            guard await pollOnce(token: token, generation: generation, callbacks: callbacks) else {
                return
            }
            guard isCurrent(generation) else { return }
            do {
                try await dependencies.sleeper.sleep(dependencies.pollInterval)
            } catch {
                return
            }
        }
    }

    private func pollOnce(token: String, generation: UInt64, callbacks: Callbacks) async -> Bool {
        callbacks.onStatus(.checking, generation)
        do {
            try await fetchAndDeliver(token: token, generation: generation, callbacks: callbacks)
            return true
        } catch is CancellationError {
            return false
        } catch let error as TwitchAPIClient.APIError {
            guard isCurrent(generation) else { return false }
            return handle(error: error, generation: generation, onStatus: callbacks.onStatus)
        } catch {
            guard isCurrent(generation) else { return false }
            callbacks.onStatus(.error("unexpected twitch notification error"), generation)
            return true
        }
    }

    private func fetchAndDeliver(token: String, generation: UInt64, callbacks: Callbacks) async throws {
        guard isCurrent(generation) else { throw CancellationError() }
        let session = try await dependencies.authenticate(token)
        guard isCurrent(generation) else { throw CancellationError() }
        let streams = try await dependencies.followedStreams(session)
        guard isCurrent(generation) else { throw CancellationError() }
        callbacks.onCurrentStreams?(streams, generation)
        guard isCurrent(generation) else { throw CancellationError() }

        let newStreams = streamBaseline.streamsToNotify(currentStreams: streams)
        streamBaseline = streamBaseline.afterSuccessfulFetch(streams)
        callbacks.onStatus(.active, generation)
        guard isCurrent(generation) else { throw CancellationError() }
        let failedIDs = await callbacks.onStreams(newStreams, session, generation)
        guard isCurrent(generation) else { throw CancellationError() }
        streamBaseline = streamBaseline.afterDeliveryFailure(failedIDs)

        do {
            let channels = try await dependencies.followedChannels(session)
            guard isCurrent(generation) else { throw CancellationError() }
            callbacks.onFollowedChannels?(channels, generation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard isCurrent(generation) else { throw CancellationError() }
            callbacks.onFollowedChannels?(nil, generation)
        }
    }

    private func handle(
        error: TwitchAPIClient.APIError,
        generation: UInt64,
        onStatus: @escaping GenerationStatusHandler
    ) -> Bool {
        switch error {
        case .invalidToken:
            onStatus(.invalidOAuthToken, generation)
            return false
        case .missingFollowedStreamsScope:
            onStatus(.missingFollowedStreamsScope, generation)
            return false
        case .network:
            streamBaseline = streamBaseline.afterNetworkFailure()
            onStatus(.error("api.twitch.tv unreachable"), generation)
            return true
        default:
            onStatus(.error(error.localizedDescription), generation)
            return true
        }
    }
}
