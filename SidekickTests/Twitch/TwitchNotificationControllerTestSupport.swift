import AppKit
import Foundation
import XCTest

@MainActor
class TwitchNotificationControllerTestSupport: XCTestCase {
    let sleepForever = TwitchSleepClient(sleep: { _ in
        try await Task.sleep(nanoseconds: UInt64.max)
    })
    let defaultsSuiteName = "TwitchNotificationControllerTests.\(UUID().uuidString)"

    func makeController(
        settings: AppSettings,
        authenticate: @escaping @Sendable (String) async throws -> TwitchAPIClient.Session,
        tokenAuthenticate: @escaping @Sendable (String) async throws -> Void = { _ in },
        followedStreams: @escaping @Sendable (TwitchAPIClient.Session) async throws -> [TwitchFollowedStream],
        followedChannels: @escaping @Sendable (
            TwitchAPIClient.Session
        ) async throws -> [TwitchFollowedChannel] = { _ in [] },
        sleeper: TwitchSleepClient,
        tokenStorage: TokenStorage? = nil,
        oauthAuthorization: TwitchOAuthAuthorization? = nil,
        tokenRead: (@MainActor @Sendable () throws -> String?)? = nil,
        keychainAccessRequest: @escaping @Sendable () async throws -> String? = { nil }
    ) -> TwitchNotificationController {
        let tokenOwner = makeTokenOwner(
            storage: tokenStorage ?? TokenStorage(value: "token"),
            read: tokenRead,
            authenticate: tokenAuthenticate
        )
        let notificationRecorder = NotificationRecorder()
        let notifications = notificationRecorder.client
        let scheduler = TwitchNotificationScheduler(notifications: notifications)
        let pollingOwner = TwitchPollingOwner(
            dependencies: .init(
                authenticate: authenticate,
                followedStreams: followedStreams,
                followedChannels: followedChannels,
                notifications: notifications,
                sleeper: sleeper,
                pollInterval: 1
            )
        )
        let deliveryOwner = TwitchDeliveryOwner(
            dependencies: .init(
                profileImages: { _, _ in
                    AsyncThrowingStream { continuation in continuation.finish() }
                },
                notifications: notifications,
                sleeper: sleeper,
                cleanupInterval: 2
            ),
            scheduler: scheduler
        )
        let testNotificationOwner = makeTestNotificationOwner(
            tokenOwner: tokenOwner,
            authenticate: authenticate,
            notificationRecorder: notificationRecorder,
            scheduler: scheduler
        )
        let keychainAccessPromptOwner = TwitchKeychainAccessPromptOwner(request: keychainAccessRequest)
        return TwitchNotificationController(
            settings: settings,
            dependencies: .init(
                notificationCenter: nil,
                tokenOwner: tokenOwner,
                pollingOwner: pollingOwner,
                deliveryOwner: deliveryOwner,
                testNotificationOwner: testNotificationOwner,
                keychainAccessPromptOwner: keychainAccessPromptOwner
            ),
            oauthAuthorization: oauthAuthorization ?? TwitchOAuthAuthorization()
        )
    }

    private func makeTestNotificationOwner(
        tokenOwner: TwitchTokenOwner,
        authenticate: @escaping @Sendable (String) async throws -> TwitchAPIClient.Session,
        notificationRecorder: NotificationRecorder,
        scheduler: TwitchNotificationScheduler
    ) -> TwitchTestNotificationOwner {
        let notifications = notificationRecorder.client
        return TwitchTestNotificationOwner(
            dependencies: .init(
                storedTokenState: { tokenOwner.storedTokenState() },
                authenticate: authenticate,
                profileImage: { username, _ in
                    (
                        profile: TwitchUserProfile(
                            id: "profile-id",
                            login: username,
                            displayName: username,
                            profileImageURL: nil
                        ),
                        imageData: nil
                    )
                },
                notifications: notifications
            ),
            scheduler: scheduler
        )
    }

    private func makeTokenOwner(
        storage: TokenStorage,
        read: (@MainActor @Sendable () throws -> String?)?,
        authenticate: @escaping @Sendable (String) async throws -> Void
    ) -> TwitchTokenOwner {
        TwitchTokenOwner(
            dependencies: .init(
                read: read ?? { storage.value },
                write: { token, _, _ in storage.value = token },
                delete: { expected, _ in
                    guard storage.value == expected else { throw KeychainStoreError.conflict }
                    storage.value = nil
                },
                authenticate: authenticate
            )
        )
    }

    func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            preconditionFailure("Unable to create test defaults suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}
