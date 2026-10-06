import Foundation
import WebKit
import XCTest

@MainActor
final class TwitchNotificationControllerTests: XCTestCase {
    func testCurrentStreamsReachObserverAndClearWhenNotificationsDisable() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        let stream = twitchTestStream(id: "live", userID: "live-user")
        let session = twitchTestSession()
        let controller = makeController(
            settings: settings,
            authenticate: { _ in session },
            followedStreams: { _ in [stream] },
            sleeper: sleepForever
        )
        defer { controller.terminate() }

        var snapshots: [[String]] = []
        controller.onOnlineStreamsChange = { snapshots.append($0.map(\.id)) }
        settings.twitchNotificationsEnabled = true
        controller.applySettings()

        await twitchEventually { snapshots == [["live"]] }
        XCTAssertEqual(controller.onlineStreams.map(\.id), ["live"])

        settings.twitchNotificationsEnabled = false
        controller.applySettings()

        XCTAssertEqual(snapshots, [["live"], []])
        XCTAssertTrue(controller.onlineStreams.isEmpty)
    }

    func testTerminalAuthorizationFailureClearsCurrentStreams() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        let stream = twitchTestStream(id: "live", userID: "live-user")
        let authentication = AuthenticationPlan()
        let sleeperGate = AsyncGate()
        let controller = makeController(
            settings: settings,
            authenticate: { _ in try await authentication.next() },
            followedStreams: { _ in [stream] },
            sleeper: .init(sleep: { _ in
                await sleeperGate.wait()
                try Task.checkCancellation()
            })
        )
        defer { controller.terminate() }

        var snapshots: [[String]] = []
        controller.onOnlineStreamsChange = { snapshots.append($0.map(\.id)) }
        settings.twitchNotificationsEnabled = true
        controller.applySettings()

        await twitchEventually { snapshots == [["live"]] }
        await twitchEventuallyAsync { await sleeperGate.hasWaiter }
        await sleeperGate.open()
        await twitchEventually { snapshots == [["live"], []] }
        XCTAssertEqual(controller.status, .polling(.invalidOAuthToken))
    }

    func testOAuthAcquisitionSavesTokenThroughController() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.twitchNotificationsEnabled = false
        let session = twitchTestSession()
        let storage = TokenStorage(value: nil)
        let tokenSaved = expectation(description: "OAuth token saved")
        var webView: TwitchOAuthTestWebView?
        let authorization = TwitchOAuthAuthorization(
            configuration: .init(
                clientID: "constructor-client-id",
                serverPort: 65432,
                requiredScopes: ["user:read:follows"]
            ),
            makeWebView: { webConfiguration in
                let view = TwitchOAuthTestWebView(frame: .zero, configuration: webConfiguration)
                webView = view
                return view
            },
            presentWindow: { _ in }
        )
        let controller = makeController(
            settings: settings,
            authenticate: { _ in session },
            followedStreams: { _ in [] },
            sleeper: sleepForever,
            tokenStorage: storage,
            oauthAuthorization: authorization
        )
        settings.twitchOAuthClientID = "saved-in-app-client-id"
        defer { controller.terminate() }
        controller.onTokenSave = { success, _ in
            if success { tokenSaved.fulfill() }
        }

        controller.startOAuthTokenAcquisition()
        let authorizationURL = try XCTUnwrap(webView?.lastRequest?.url)
        let components = try XCTUnwrap(URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false))
        let values = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        XCTAssertEqual(values["client_id"], "saved-in-app-client-id")
        let state = try XCTUnwrap(
            components.queryItems?.first(where: { $0.name == "state" })?.value
        )
        let redirectURI = try XCTUnwrap(
            components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value
        )
        let fragment = "#access_token=controller-token&scope=user%3Aread%3Afollows&state=\(state)&token_type=bearer"
        let callbackURL = try XCTUnwrap(URL(string: redirectURI + fragment))
        webView?.stopLoading()
        _ = webView?.load(URLRequest(url: callbackURL))

        await fulfillment(of: [tokenSaved], timeout: 2)
        XCTAssertEqual(storage.value, "controller-token")
    }

    private let sleepForever = TwitchSleepClient(sleep: { _ in
        try await Task.sleep(nanoseconds: UInt64.max)
    })
    private let defaultsSuiteName = "TwitchNotificationControllerTests.\(UUID().uuidString)"

    private func makeController(
        settings: AppSettings,
        authenticate: @escaping @Sendable (String) async throws -> TwitchAPIClient.Session,
        followedStreams: @escaping @Sendable (TwitchAPIClient.Session) async throws -> [TwitchFollowedStream],
        sleeper: TwitchSleepClient,
        tokenStorage: TokenStorage? = nil,
        oauthAuthorization: TwitchOAuthAuthorization? = nil
    ) -> TwitchNotificationController {
        let tokenOwner = makeTokenOwner(storage: tokenStorage ?? TokenStorage(value: "token"))
        let notificationRecorder = NotificationRecorder()
        let notifications = notificationRecorder.client
        let scheduler = TwitchNotificationScheduler(notifications: notifications)
        let pollingOwner = TwitchPollingOwner(
            dependencies: .init(
                authenticate: authenticate,
                followedStreams: followedStreams,
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
        let testNotificationOwner = TwitchTestNotificationOwner(
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
        return TwitchNotificationController(
            settings: settings,
            dependencies: .init(
                notificationCenter: nil,
                tokenOwner: tokenOwner,
                pollingOwner: pollingOwner,
                deliveryOwner: deliveryOwner,
                testNotificationOwner: testNotificationOwner
            ),
            oauthAuthorization: oauthAuthorization ?? TwitchOAuthAuthorization()
        )
    }

    private func makeTokenOwner(storage: TokenStorage) -> TwitchTokenOwner {
        return TwitchTokenOwner(
            dependencies: .init(
                read: { storage.value },
                write: { token, _ in storage.value = token },
                delete: { storage.value = nil },
                authenticate: { _ in }
            )
        )
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            preconditionFailure("Unable to create test defaults suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}

private actor AuthenticationPlan {
    private var requestCount = 0

    func next() throws -> TwitchAPIClient.Session {
        requestCount += 1
        guard requestCount == 1 else {
            throw TwitchAPIClient.APIError.invalidToken
        }
        return TwitchAPIClient.Session(accessToken: "token", clientID: "client", userID: "user")
    }
}
