import Foundation
import UserNotifications
import XCTest

@MainActor
final class MacArtifactCleanupNotifierTests: XCTestCase {
    func testDefaultNotificationCenterAcceptsCleanupSummaryWhenAuthorized() async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            throw XCTSkip("Notification integration requires pre-authorized access; it never prompts.")
        }

        let previousDelegate = center.delegate
        let presentationSuppressor = NotificationPresentationSuppressor()
        center.delegate = presentationSuppressor
        defer { center.delegate = previousDelegate }

        let title = "Sidekick cleanup integration \(UUID().uuidString)"
        let body = "1 removed; 0 skipped from integration-test."
        let notifier = MacArtifactCleanupNotifier()
        let sendTask = try XCTUnwrap(notifier.send(title: title, body: body, isCurrent: { true }))
        let resultIdentifier = await sendTask.value
        let identifier = try XCTUnwrap(resultIdentifier)
        defer {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        }

        XCTAssertTrue(identifier.hasPrefix("mac-artifact-cleanup-"))
    }
}

private final class NotificationPresentationSuppressor: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
