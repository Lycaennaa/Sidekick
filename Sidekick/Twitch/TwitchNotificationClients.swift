import Foundation
@preconcurrency import UserNotifications

struct TwitchSleepClient: Sendable {
    let sleep: @Sendable (TimeInterval) async throws -> Void

    static let live = TwitchSleepClient { interval in
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
}

struct TwitchNotificationCenterClient: Sendable {
    let authorizationStatus: @MainActor @Sendable () async -> UNAuthorizationStatus
    let requestAuthorization: @MainActor @Sendable () async throws -> Bool
    let add: @MainActor @Sendable (UNNotificationRequest) async throws -> Void
    let pendingIdentifiers: @MainActor @Sendable () async -> Set<String>
    let removePending: @MainActor @Sendable ([String]) -> Void
    let removeDelivered: @MainActor @Sendable ([String]) -> Void

    @MainActor
    static func live(_ center: UNUserNotificationCenter) -> TwitchNotificationCenterClient {
        TwitchNotificationCenterClient(
            authorizationStatus: {
                await center.notificationSettings().authorizationStatus
            },
            requestAuthorization: {
                try await center.requestAuthorization(options: [.alert, .sound])
            },
            add: { request in
                try await center.add(request)
            },
            pendingIdentifiers: {
                Set(await center.pendingNotificationRequests().map(\.identifier))
            },
            removePending: { identifiers in
                center.removePendingNotificationRequests(withIdentifiers: identifiers)
            },
            removeDelivered: { identifiers in
                center.removeDeliveredNotifications(withIdentifiers: identifiers)
            }
        )
    }
}

enum TwitchNotificationPermissionResult: Equatable, Sendable {
    case granted
    case denied
    case requestFailed
}
