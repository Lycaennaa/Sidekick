import Foundation
@preconcurrency import UserNotifications
import XCTest

@MainActor
func twitchTestSession() -> TwitchAPIClient.Session {
    .init(accessToken: "token", clientID: "client", userID: "user")
}

@MainActor
func twitchTestStream(id: String, userID: String) -> TwitchFollowedStream {
    TwitchFollowedStream(
        id: id,
        userID: userID,
        userLogin: userID,
        userName: userID,
        title: "title",
        gameName: "game"
    )
}

@MainActor
func makeTwitchDeliveryOwner(
    source: ProfileResultSource,
    notifications: NotificationRecorder
) -> TwitchDeliveryOwner {
    TwitchDeliveryOwner(
        dependencies: .init(
            profileImages: { _, _ in source.makeStream() },
            notifications: notifications.client,
            sleeper: .init(sleep: { _ in
                try await Task.sleep(nanoseconds: UInt64.max)
            }),
            cleanupInterval: 2
        )
    )
}

@MainActor
func twitchEventually(
    _ predicate: @MainActor () -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<200 {
        if predicate() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Condition was not met", file: file, line: line)
}

func twitchEventuallyAsync(
    _ predicate: @Sendable () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<200 {
        if await predicate() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Condition was not met", file: file, line: line)
}

final class ProfileResultSource: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<TwitchAPIClient.ProfileImageResult, Error>.Continuation?

    var hasSubscriber: Bool {
        lock.withLock { continuation != nil }
    }

    func makeStream() -> AsyncThrowingStream<TwitchAPIClient.ProfileImageResult, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { self.continuation = continuation }
        }
    }

    func yield(_ result: TwitchAPIClient.ProfileImageResult) {
        lock.withLock { continuation }?.yield(result)
    }

    func finish() {
        lock.withLock { continuation }?.finish()
    }
}

final class NotificationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [UNNotificationRequest] = []
    private var pending: Set<String> = []
    private var removed: [String] = []

    var requestIdentifiers: [String] {
        lock.withLock { requests.map(\.identifier) }
    }

    var systemPendingIdentifiers: Set<String> {
        get { lock.withLock { pending } }
        set { lock.withLock { pending = newValue } }
    }

    var removedPendingIdentifiers: [String] {
        lock.withLock { removed }
    }

    var client: TwitchNotificationCenterClient {
        makeClient(pendingIdentifiers: { self.lock.withLock { self.pending } })
    }

    func makeClient(
        pendingIdentifiers: @escaping @MainActor @Sendable () async -> Set<String>
    ) -> TwitchNotificationCenterClient {
        TwitchNotificationCenterClient(
            authorizationStatus: { .authorized },
            requestAuthorization: { true },
            add: { request in
                self.lock.withLock {
                    self.requests.append(request)
                    self.pending.insert(request.identifier)
                }
            },
            pendingIdentifiers: pendingIdentifiers,
            removePending: { identifiers in
                self.lock.withLock {
                    self.removed.append(contentsOf: identifiers)
                    self.pending.subtract(identifiers)
                }
            },
            removeDelivered: { _ in }
        )
    }
}
