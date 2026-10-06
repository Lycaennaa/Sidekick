import UserNotifications

@MainActor
struct TwitchNotificationAuthorization {
    let notifications: TwitchNotificationCenterClient

    func requestPermission(
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async -> TwitchNotificationPermissionResult {
        let authorizationStatus = await notifications.authorizationStatus()
        guard isCurrent() else { return .requestFailed }

        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            do {
                let granted = try await notifications.requestAuthorization()
                guard isCurrent() else { return .requestFailed }
                return granted ? .granted : .denied
            } catch is CancellationError {
                return .requestFailed
            } catch {
                return isCurrent() ? .requestFailed : .denied
            }
        @unknown default:
            return .requestFailed
        }
    }
}
