@preconcurrency import UserNotifications
import XCTest

@MainActor
final class TwitchPollingOwnerTests: XCTestCase {
    func testPollingOwnerOwnsLoopCancellation() async {
        let sleeper = CancellationRecordingSleeper()
        let notifications = NotificationRecorder()
        let pollingSession = twitchTestSession()
        let followedChannel = TwitchFollowedChannel(id: "channel-id", login: "channel", name: "Channel")
        let owner = TwitchPollingOwner(
            dependencies: .init(
                authenticate: { _ in pollingSession },
                followedStreams: { _ in [] },
                followedChannels: { _ in [followedChannel] },
                notifications: notifications.client,
                sleeper: .init(sleep: { interval in try await sleeper.sleep(interval) }),
                pollInterval: 150
            )
        )
        var statuses: [TwitchPollingOwner.Status] = []
        var followedChannelIDs: [String] = []
        owner.start(
            token: "token",
            onStatus: { statuses.append($0) },
            onStreams: { _, _, _ in [] },
            onFollowedChannels: { channels, _ in
                followedChannelIDs = channels?.map(\.id) ?? []
            }
        )
        await twitchEventually { statuses.contains(.active) }
        await twitchEventually { followedChannelIDs == ["channel-id"] }

        owner.stop()
        await twitchEventuallyAsync { await sleeper.wasCancelled }

        XCTAssertFalse(owner.isRunning)
        XCTAssertNil(owner.token)
        XCTAssertEqual(
            Array(statuses.prefix(3)),
            [.requestingPermission, .checking, .active]
        )
    }

    func testPollingOwnerReportsDeniedPermissionAndStops() async {
        let session = twitchTestSession()
        let owner = TwitchPollingOwner(
            dependencies: .init(
                authenticate: { _ in session },
                followedStreams: { _ in [] },
                followedChannels: { _ in [] },
                notifications: makeTwitchNotificationClient(authorizationStatus: .denied),
                sleeper: .init(sleep: { _ in try Task.checkCancellation() }),
                pollInterval: 1
            )
        )
        var statuses: [TwitchPollingOwner.Status] = []

        owner.start(
            token: "token",
            onStatus: { statuses.append($0) },
            onStreams: { _, _, _ in [] }
        )

        await twitchEventually { statuses.contains(.notificationPermissionDenied) }
        await twitchEventually { !owner.isRunning }

        XCTAssertEqual(statuses, [.requestingPermission, .notificationPermissionDenied])
    }
    func testStoppingDuringPermissionRequestEmitsNoLateStatus() async {
        let permissionGate = AsyncGate()
        let cancellationGate = AsyncGate()
        let session = twitchTestSession()
        let notifications = TwitchNotificationCenterClient(
            authorizationStatus: {
                await permissionGate.wait()
                await cancellationGate.wait()
                return .authorized
            },
            requestAuthorization: { true },
            add: { _ in },
            pendingIdentifiers: { [] },
            removePending: { _ in },
            removeDelivered: { _ in }
        )
        let owner = TwitchPollingOwner(
            dependencies: .init(
                authenticate: { _ in session },
                followedStreams: { _ in [] },
                followedChannels: { _ in [] },
                notifications: notifications,
                sleeper: .init(sleep: { _ in try Task.checkCancellation() }),
                pollInterval: 1
            )
        )
        var statuses: [TwitchPollingOwner.Status] = []

        owner.start(
            token: "token",
            onStatus: { statuses.append($0) },
            onStreams: { _, _, _ in [] }
        )
        await twitchEventuallyAsync { await permissionGate.hasWaiter }

        owner.stop()
        await permissionGate.open()
        await twitchEventuallyAsync { await cancellationGate.hasWaiter }
        await cancellationGate.open()
        await Task.yield()

        XCTAssertEqual(statuses, [.requestingPermission])
    }

    func testPollingOwnerRetriesPermissionRequestErrors() async {
        let permissionPlan = PermissionRequestPlan()
        let retryGate = AsyncGate()
        let session = twitchTestSession()
        let owner = TwitchPollingOwner(
            dependencies: .init(
                authenticate: { _ in session },
                followedStreams: { _ in [] },
                followedChannels: { _ in [] },
                notifications: makeTwitchNotificationClient(
                    authorizationStatus: .notDetermined,
                    requestAuthorization: { try await permissionPlan.request() }
                ),
                sleeper: .init(sleep: { _ in
                    await retryGate.wait()
                    try Task.checkCancellation()
                }),
                pollInterval: 1
            )
        )
        var statuses: [TwitchPollingOwner.Status] = []

        owner.start(
            token: "token",
            onStatus: { statuses.append($0) },
            onStreams: { _, _, _ in [] }
        )

        await twitchEventually { statuses.contains(.notificationPermissionError) }
        await twitchEventuallyAsync { await retryGate.hasWaiter }
        await retryGate.open()
        await twitchEventually { statuses.contains(.active) }
        await twitchEventuallyAsync { await retryGate.hasWaiter }

        owner.stop()
        await retryGate.open()
        await twitchEventually { !owner.isRunning }

        XCTAssertEqual(
            Array(statuses.prefix(4)),
            [.requestingPermission, .notificationPermissionError, .checking, .active]
        )
    }

    func testPollingOwnerReportsInvalidOAuthTokenAndStops() async {
        let session = twitchTestSession()
        let owner = TwitchPollingOwner(
            dependencies: .init(
                authenticate: { _ in throw TwitchAPIClient.APIError.invalidToken },
                followedStreams: { _ in [] },
                followedChannels: { _ in [] },
                notifications: makeTwitchNotificationClient(authorizationStatus: .authorized),
                sleeper: .init(sleep: { _ in
                    try await Task.sleep(nanoseconds: UInt64.max)
                }),
                pollInterval: 1
            )
        )
        var statuses: [TwitchPollingOwner.Status] = []

        owner.start(
            token: session.accessToken,
            onStatus: { statuses.append($0) },
            onStreams: { _, _, _ in [] }
        )

        await twitchEventually { statuses.contains(.invalidOAuthToken) }
        await twitchEventually { !owner.isRunning }

        XCTAssertEqual(
            statuses,
            [.requestingPermission, .checking, .invalidOAuthToken]
        )
    }

    func testPollingOwnerReportsMissingFollowedStreamsScopeAndStops() async {
        let session = twitchTestSession()
        let owner = TwitchPollingOwner(
            dependencies: .init(
                authenticate: { _ in throw TwitchAPIClient.APIError.missingFollowedStreamsScope },
                followedStreams: { _ in [] },
                followedChannels: { _ in [] },
                notifications: makeTwitchNotificationClient(authorizationStatus: .authorized),
                sleeper: .init(sleep: { _ in
                    try await Task.sleep(nanoseconds: UInt64.max)
                }),
                pollInterval: 1
            )
        )
        var statuses: [TwitchPollingOwner.Status] = []

        owner.start(
            token: session.accessToken,
            onStatus: { statuses.append($0) },
            onStreams: { _, _, _ in [] }
        )

        await twitchEventually { statuses.contains(.missingFollowedStreamsScope) }
        await twitchEventually { !owner.isRunning }

        XCTAssertEqual(
            statuses,
            [.requestingPermission, .checking, .missingFollowedStreamsScope]
        )
    }

    func testPollingOwnerRetriesNetworkErrorsUntilCancelled() async {
        let sleeper = CancellationRecordingSleeper()
        let notifications = NotificationRecorder()
        let session = twitchTestSession()
        let owner = TwitchPollingOwner(
            dependencies: .init(
                authenticate: { _ in throw TwitchAPIClient.APIError.network },
                followedStreams: { _ in [] },
                followedChannels: { _ in [] },
                notifications: notifications.client,
                sleeper: .init(sleep: { interval in try await sleeper.sleep(interval) }),
                pollInterval: 150
            )
        )
        var statuses: [TwitchPollingOwner.Status] = []

        owner.start(
            token: session.accessToken,
            onStatus: { statuses.append($0) },
            onStreams: { _, _, _ in [] }
        )

        await twitchEventually { statuses.contains(.error("api.twitch.tv unreachable")) }
        XCTAssertEqual(
            statuses,
            [.requestingPermission, .checking, .error("api.twitch.tv unreachable")]
        )

        owner.stop()
        await twitchEventuallyAsync { await sleeper.wasCancelled }
        XCTAssertFalse(owner.isRunning)
    }

    func testPollingOwnerNotifiesStreamsAfterNetworkRecoveryBeforeFirstFetch() async {
        let sleeperGate = AsyncGate()
        let stream = twitchTestStream(id: "recovered", userID: "recovered-user")
        let responses = RecoveringPollingResponses(stream: stream)
        let notifications = NotificationRecorder()
        let session = twitchTestSession()
        let owner = TwitchPollingOwner(
            dependencies: .init(
                authenticate: { _ in session },
                followedStreams: { _ in try await responses.next() },
                followedChannels: { _ in [] },
                notifications: notifications.client,
                sleeper: .init(sleep: { _ in
                    await sleeperGate.wait()
                    try Task.checkCancellation()
                }),
                pollInterval: 1
            )
        )
        var statuses: [TwitchPollingOwner.Status] = []
        var deliveredStreamIDs: [[String]] = []

        owner.start(
            token: session.accessToken,
            onStatus: { statuses.append($0) },
            onStreams: { streams, _, _ in
                deliveredStreamIDs.append(streams.map(\.id))
                return []
            }
        )

        await twitchEventually { statuses.contains(.error("api.twitch.tv unreachable")) }
        await twitchEventuallyAsync { await sleeperGate.hasWaiter }
        await sleeperGate.open()
        await twitchEventually { deliveredStreamIDs == [[stream.id]] }

        XCTAssertEqual(deliveredStreamIDs, [[stream.id]])
        await twitchEventuallyAsync { await sleeperGate.hasWaiter }
        owner.stop()
        await sleeperGate.open()
        await twitchEventually { !owner.isRunning }
    }

    func testStoppingBeforePollingTaskStartsEmitsNoStatus() async {
        let notifications = NotificationRecorder()
        let session = twitchTestSession()
        let owner = TwitchPollingOwner(
            dependencies: .init(
                authenticate: { _ in session },
                followedStreams: { _ in [] },
                followedChannels: { _ in [] },
                notifications: notifications.client,
                sleeper: .init(sleep: { _ in
                    try await Task.sleep(nanoseconds: UInt64.max)
                }),
                pollInterval: 1
            )
        )
        var statuses: [TwitchPollingOwner.Status] = []

        owner.start(
            token: "token",
            onStatus: { statuses.append($0) },
            onStreams: { _, _, _ in [] }
        )
        owner.stop()
        await Task.yield()

        XCTAssertTrue(statuses.isEmpty)
    }
    func testPollingCallbacksSeparateStatusesAndRetryFailedDeliveryIDs() async {
        let sleeperGate = AsyncGate()
        let existing = twitchTestStream(id: "existing", userID: "existing-user")
        let new = twitchTestStream(id: "new", userID: "new-user")
        let responses = PollingResponses([
            [existing],
            [existing, new],
            [existing, new]
        ])
        let session = twitchTestSession()
        let notifications = NotificationRecorder()
        let owner = TwitchPollingOwner(
            dependencies: .init(
                authenticate: { _ in session },
                followedStreams: { _ in await responses.next() },
                followedChannels: { _ in [] },
                notifications: notifications.client,
                sleeper: .init(sleep: { _ in
                    await sleeperGate.wait()
                    try Task.checkCancellation()
                }),
                pollInterval: 1
            )
        )
        var statuses: [TwitchPollingOwner.Status] = []
        var deliveredStreamIDs: [[String]] = []

        var currentStreamIDs: [[String]] = []
        owner.start(
            token: "token",
            onStatus: { statuses.append($0) },
            onStreams: { streams, _, _ in
                deliveredStreamIDs.append(streams.map(\.id))
                return Set(streams.map(\.id))
            },
            onCurrentStreams: { streams, _ in
                currentStreamIDs.append(streams.map(\.id))
            }
        )

        await twitchEventually { deliveredStreamIDs.count == 1 }
        XCTAssertEqual(
            Array(statuses.prefix(3)),
            [.requestingPermission, .checking, .active]
        )
        XCTAssertEqual(deliveredStreamIDs, [[]])

        await twitchEventuallyAsync { await sleeperGate.hasWaiter }
        await sleeperGate.open()
        await twitchEventually { deliveredStreamIDs.count == 2 }
        XCTAssertEqual(deliveredStreamIDs[1], ["new"])

        await twitchEventuallyAsync { await sleeperGate.hasWaiter }
        await sleeperGate.open()
        await twitchEventually { deliveredStreamIDs.count == 3 }
        XCTAssertEqual(deliveredStreamIDs[2], ["new"])
        XCTAssertEqual(currentStreamIDs, [["existing"], ["existing", "new"], ["existing", "new"]])

        await twitchEventuallyAsync { await sleeperGate.hasWaiter }
        owner.stop()
        await sleeperGate.open()
        XCTAssertFalse(owner.isRunning)
    }
}

@MainActor
final class TwitchPollingOwnerStatusTests: XCTestCase {
    func testPollingStatusMessagesRemainStable() {
        let statuses: [(TwitchPollingOwner.Status, String)] = [
            (.requestingPermission, "requesting notification permission…"),
            (.checking, "checking twitch…"),
            (
                .active,
                "watching followed channels · checks every \(TwitchAPIClient.pollInterval.formatted()) seconds"
            ),
            (.notificationPermissionDenied, "macos notifications are denied for this app"),
            (.invalidOAuthToken, "oauth token is invalid or expired"),
            (.missingFollowedStreamsScope, "token needs user:read:follows permission"),
            (.notificationPermissionError, "could not request macos notification permission; retrying"),
            (.error("custom polling error"), "custom polling error")
        ]

        for (status, expectedMessage) in statuses {
            XCTAssertEqual(status.message, expectedMessage)
        }
    }
}
@MainActor
private func makeTwitchNotificationClient(
    authorizationStatus: UNAuthorizationStatus,
    requestAuthorization: @escaping @MainActor @Sendable () async throws -> Bool = { true }
) -> TwitchNotificationCenterClient {
    TwitchNotificationCenterClient(
        authorizationStatus: { authorizationStatus },
        requestAuthorization: requestAuthorization,
        add: { _ in },
        pendingIdentifiers: { [] },
        removePending: { _ in },
        removeDelivered: { _ in }
    )
}

private actor PermissionRequestPlan {
    private var shouldFail = true

    func request() throws -> Bool {
        guard shouldFail else { return true }
        shouldFail = false
        throw PermissionRequestError()
    }
}

private struct PermissionRequestError: Error {}

private actor PollingResponses {
    private let responses: [[TwitchFollowedStream]]
    private var index = 0

    init(_ responses: [[TwitchFollowedStream]]) {
        self.responses = responses
    }

    func next() -> [TwitchFollowedStream] {
        guard !responses.isEmpty else { return [] }
        let response = responses[min(index, responses.count - 1)]
        index += 1
        return response
    }
}

private actor RecoveringPollingResponses {
    private let stream: TwitchFollowedStream
    private var shouldFail = true

    init(stream: TwitchFollowedStream) {
        self.stream = stream
    }

    func next() throws -> [TwitchFollowedStream] {
        guard shouldFail else { return [stream] }
        shouldFail = false
        throw TwitchAPIClient.APIError.network
    }
}
