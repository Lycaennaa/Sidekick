import AppKit
import CoreGraphics
import UserNotifications
import XCTest

@MainActor
final class PermissionsSettingsLiveIntegrationTests: XCTestCase {
    func testDefaultPermissionStatusReadsRealSystemAuthorization() async throws {
        let screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        let notificationStatus = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
        let view = PermissionsSettingsView()
        view.refresh()
        let refreshTask = try XCTUnwrap(view.notificationRefreshTask)
        await refreshTask.value

        let screenStatus = try XCTUnwrap(
            findField("Permissions.ScreenRecording.Status", in: view)
        )
        let notificationStatusLabel = try XCTUnwrap(
            findField("Permissions.Notifications.Status", in: view)
        )
        XCTAssertEqual(screenStatus.stringValue, screenRecordingAllowed ? "Allowed" : "Not Allowed")
        XCTAssertEqual(notificationStatusLabel.stringValue, description(for: notificationStatus))
    }

    private func findField(_ identifier: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.identifier?.rawValue == identifier {
            return field
        }
        for subview in view.subviews {
            if let field = findField(identifier, in: subview) {
                return field
            }
        }
        return nil
    }

    private func description(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            "Not Requested"
        case .denied:
            "Not Allowed"
        case .authorized, .provisional, .ephemeral:
            "Allowed"
        @unknown default:
            "Unknown"
        }
    }
}
