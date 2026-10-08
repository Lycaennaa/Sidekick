import AppKit
import CoreGraphics
import UserNotifications
import XCTest

@MainActor
final class PermissionsSettingsViewTests: XCTestCase {
    func testPermissionPageExposesLiveScreenStatusAndRequestActions() throws {
        _ = NSApplication.shared
        let screenRecordingAllowed = CGPreflightScreenCaptureAccess()
        let view = PermissionsSettingsView()

        let screenRecordingStatusLabel = try XCTUnwrap(
            findView(NSTextField.self, identifier: "Permissions.ScreenRecording.Status", in: view)
        )
        let notificationStatusLabel = try XCTUnwrap(
            findView(NSTextField.self, identifier: "Permissions.Notifications.Status", in: view)
        )
        XCTAssertEqual(screenRecordingStatusLabel.stringValue, screenRecordingAllowed ? "Allowed" : "Not Allowed")
        XCTAssertEqual(notificationStatusLabel.stringValue, "Checking…")

        let requestScreenRecordingButton = try XCTUnwrap(
            findView(NSButton.self, identifier: "Permissions.ScreenRecording.Request", in: view)
        )
        let requestNotificationButton = try XCTUnwrap(
            findView(NSButton.self, identifier: "Permissions.Notifications.Request", in: view)
        )
        let screenRecordingSettingsButton = try XCTUnwrap(
            findView(NSButton.self, identifier: "Permissions.ScreenRecording.Settings", in: view)
        )
        let notificationSettingsButton = try XCTUnwrap(
            findView(NSButton.self, identifier: "Permissions.Notifications.Settings", in: view)
        )
        XCTAssertEqual(requestScreenRecordingButton.isEnabled, !screenRecordingAllowed)
        XCTAssertFalse(requestNotificationButton.isEnabled)
        XCTAssertTrue(screenRecordingSettingsButton.isEnabled)
        XCTAssertTrue(notificationSettingsButton.isEnabled)
        XCTAssertTrue(requestScreenRecordingButton.target === view)
        XCTAssertTrue(requestNotificationButton.target === view)
        XCTAssertTrue(requestScreenRecordingButton.superview === screenRecordingStatusLabel.superview)
        XCTAssertTrue(screenRecordingSettingsButton.superview === screenRecordingStatusLabel.superview)
        XCTAssertTrue(requestNotificationButton.superview === notificationStatusLabel.superview)
        XCTAssertTrue(notificationSettingsButton.superview === notificationStatusLabel.superview)
    }

    func testOlderNotificationRefreshCannotOverwriteNewerStatus() async throws {
        let gate = NotificationStatusGate()
        let view = PermissionsSettingsView(notificationCenterClient: makeNotificationClient(
            authorizationStatus: { await gate.read() }
        ))
        view.refresh()
        let olderRefresh = try XCTUnwrap(view.notificationRefreshTask)
        await gate.waitForFirstRead()

        view.refresh()
        let newerRefresh = try XCTUnwrap(view.notificationRefreshTask)
        await newerRefresh.value
        let statusLabel = try XCTUnwrap(
            findView(NSTextField.self, identifier: "Permissions.Notifications.Status", in: view)
        )
        XCTAssertEqual(statusLabel.stringValue, "Not Allowed")

        gate.finishFirstRead(with: .authorized)
        await olderRefresh.value
        XCTAssertEqual(statusLabel.stringValue, "Not Allowed")
    }

    func testNotificationRequestUsesSharedAuthorizationFlow() async throws {
        let statuses = NotificationStatusSequence([.notDetermined, .notDetermined, .authorized])
        let requests = NotificationRequestRecorder()
        let view = PermissionsSettingsView(notificationCenterClient: makeNotificationClient(
            authorizationStatus: { statuses.next() },
            requestAuthorization: { await requests.request() }
        ))
        view.refresh()
        let refreshTask = try XCTUnwrap(view.notificationRefreshTask)
        await refreshTask.value

        let requestButton = try XCTUnwrap(
            findView(NSButton.self, identifier: "Permissions.Notifications.Request", in: view)
        )
        XCTAssertTrue(requestButton.isEnabled)
        let action = try XCTUnwrap(requestButton.action)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: requestButton.target, from: requestButton))
        let requestTask = try XCTUnwrap(view.notificationRequestTask)
        await requestTask.value

        let statusLabel = try XCTUnwrap(
            findView(NSTextField.self, identifier: "Permissions.Notifications.Status", in: view)
        )
        XCTAssertEqual(statusLabel.stringValue, "Allowed")
        XCTAssertFalse(requestButton.isEnabled)
        XCTAssertEqual(requests.count, 1)
    }

    func testCancelledNotificationRequestRestoresControls() async throws {
        let statuses = NotificationStatusSequence([.notDetermined, .notDetermined])
        let gate = NotificationRequestGate()
        let view = PermissionsSettingsView(notificationCenterClient: makeNotificationClient(
            authorizationStatus: { statuses.next() },
            requestAuthorization: { await gate.request() }
        ))
        view.refresh()
        let refreshTask = try XCTUnwrap(view.notificationRefreshTask)
        await refreshTask.value
        let requestButton = try XCTUnwrap(
            findView(NSButton.self, identifier: "Permissions.Notifications.Request", in: view)
        )

        let action = try XCTUnwrap(requestButton.action)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: requestButton.target, from: requestButton))
        let requestTask = try XCTUnwrap(view.notificationRequestTask)
        await gate.waitForRequest()
        requestTask.cancel()
        gate.finishRequest()
        await requestTask.value

        let statusLabel = try XCTUnwrap(
            findView(NSTextField.self, identifier: "Permissions.Notifications.Status", in: view)
        )
        XCTAssertEqual(statusLabel.stringValue, "Not Requested")
        XCTAssertTrue(requestButton.isEnabled)
    }

    private func makeNotificationClient(
        authorizationStatus: @escaping @MainActor @Sendable () async -> UNAuthorizationStatus,
        requestAuthorization: @escaping @MainActor @Sendable () async throws -> Bool = { true }
    ) -> TwitchNotificationCenterClient {
        TwitchNotificationCenterClient(
            authorizationStatus: authorizationStatus,
            requestAuthorization: requestAuthorization,
            add: { _ in },
            pendingIdentifiers: { [] },
            removePending: { _ in },
            removeDelivered: { _ in }
        )
    }

    @MainActor
    private final class NotificationStatusSequence {
        private var statuses: [UNAuthorizationStatus]

        init(_ statuses: [UNAuthorizationStatus]) {
            self.statuses = statuses
        }

        func next() -> UNAuthorizationStatus {
            statuses.removeFirst()
        }
    }

    @MainActor
    private final class NotificationRequestRecorder {
        private(set) var count = 0

        func request() async -> Bool {
            count += 1
            return true
        }
    }

    @MainActor
    private final class NotificationStatusGate {
        private var readCount = 0
        private var firstReadStarted = false
        private var firstReadWaiter: CheckedContinuation<Void, Never>?
        private var firstReadResult: CheckedContinuation<UNAuthorizationStatus, Never>?

        func read() async -> UNAuthorizationStatus {
            readCount += 1
            guard readCount == 1 else { return .denied }
            firstReadStarted = true
            firstReadWaiter?.resume()
            firstReadWaiter = nil
            return await withCheckedContinuation { firstReadResult = $0 }
        }

        func waitForFirstRead() async {
            guard !firstReadStarted else { return }
            await withCheckedContinuation { firstReadWaiter = $0 }
        }

        func finishFirstRead(with status: UNAuthorizationStatus) {
            firstReadResult?.resume(returning: status)
            firstReadResult = nil
        }
    }

    private func findView<ViewType: NSView>(
        _ type: ViewType.Type,
        identifier: String,
        in view: NSView
    ) -> ViewType? {
        if let match = view as? ViewType, match.identifier?.rawValue == identifier {
            return match
        }
        for subview in view.subviews {
            if let match = findView(type, identifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }
}

@MainActor
private final class NotificationRequestGate {
    private var requestStarted = false
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var requestResult: CheckedContinuation<Bool, Never>?

    func request() async -> Bool {
        await withCheckedContinuation { continuation in
            requestResult = continuation
            requestStarted = true
            requestWaiter?.resume()
            requestWaiter = nil
        }
    }

    func waitForRequest() async {
        guard !requestStarted else { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func finishRequest() {
        requestResult?.resume(returning: true)
        requestResult = nil
    }
}
