import AppKit
import Foundation
import WebKit
import XCTest

@MainActor
final class TwitchNotificationControllerTests: TwitchNotificationControllerTestSupport {
    func testAMOLEDBlackThemeMakesChannelPickerBlack() throws {
        _ = NSApplication.shared
        let previousAppearance = AppTheme.appearance
        defer { AppTheme.apply(previousAppearance) }
        AppTheme.apply(.amoledBlack)

        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        let session = twitchTestSession()
        let controller = makeController(
            settings: settings,
            authenticate: { _ in session },
            followedStreams: { _ in [] },
            sleeper: sleepForever
        )
        defer { controller.terminate() }
        let view = TwitchNotificationView(settings: settings, controller: controller)

        func findChannelPicker(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView, scrollView.documentView is NSTableView {
                return scrollView
            }
            for subview in view.subviews {
                if let scrollView = findChannelPicker(in: subview) { return scrollView }
            }
            return nil
        }

        let channelPicker = try XCTUnwrap(findChannelPicker(in: view))
        let channelTable = try XCTUnwrap(channelPicker.documentView as? NSTableView)
        XCTAssertEqual(channelPicker.backgroundColor, .black)
        XCTAssertEqual(channelTable.backgroundColor, .black)

        AppTheme.apply(.dark)
        view.refresh()
        XCTAssertEqual(channelPicker.backgroundColor, .controlBackgroundColor)
        XCTAssertEqual(channelTable.backgroundColor, .controlBackgroundColor)
    }

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

    func testOnlySelectedFollowedChannelsDeliverLiveNotifications() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        let session = twitchTestSession()
        settings.twitchNotificationChannelMode = .onlySelected
        settings.setTwitchSelectedChannelIDs(["selected-user"], for: .onlySelected)
        let existing = twitchTestStream(id: "existing", userID: "selected-user")
        let selected = twitchTestStream(id: "selected", userID: "selected-user")
        let excluded = twitchTestStream(id: "excluded", userID: "excluded-user")
        let responses = ControllerStreamResponses([
            [existing],
            [existing, selected, excluded]
        ])
        let pollingGate = AsyncGate()
        let controller = makeController(
            settings: settings,
            authenticate: { _ in session },
            followedStreams: { _ in await responses.next() },
            followedChannels: { _ in
                [
                    TwitchFollowedChannel(id: "selected-user", login: "selected", name: "Selected"),
                    TwitchFollowedChannel(id: "excluded-user", login: "excluded", name: "Excluded")
                ]
            },
            sleeper: .init(sleep: { _ in
                await pollingGate.wait()
                try Task.checkCancellation()
            })
        )
        defer { controller.terminate() }

        var deliveredChannelIDs: [String] = []
        controller.onStreamLive = { stream, _ in deliveredChannelIDs.append(stream.userID) }
        settings.twitchNotificationsEnabled = true
        controller.applySettings()
        await twitchEventuallyAsync { await pollingGate.hasWaiter }

        await pollingGate.open()
        await twitchEventually { deliveredChannelIDs == ["selected-user"] }

        XCTAssertEqual(controller.onlineStreams.map(\.userID), [
            "selected-user",
            "selected-user",
            "excluded-user"
        ])
    }

    func testUnfollowedChannelsArePrunedFromBothModeSelections() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.twitchNotificationChannelMode = .allExceptSelected
        settings.setTwitchSelectedChannelIDs(["unfollowed-user"], for: .allExceptSelected)
        settings.setTwitchSelectedChannelIDs(["unfollowed-user"], for: .onlySelected)
        let session = twitchTestSession()
        let channel = TwitchFollowedChannel(id: "unfollowed-user", login: "former", name: "Former")
        let channelResponses = ControllerFollowedChannelResponses([[channel], []])
        let streamResponses = ControllerStreamResponses([[], []])
        let pollingGate = AsyncGate()
        let controller = makeController(
            settings: settings,
            authenticate: { _ in session },
            followedStreams: { _ in await streamResponses.next() },
            followedChannels: { _ in await channelResponses.next() },
            sleeper: .init(sleep: { _ in
                await pollingGate.wait()
                try Task.checkCancellation()
            })
        )
        defer { controller.terminate() }

        settings.twitchNotificationsEnabled = true
        controller.applySettings()
        await twitchEventuallyAsync { await pollingGate.hasWaiter }
        XCTAssertEqual(controller.followedChannels.map(\.id), ["unfollowed-user"])

        await pollingGate.open()
        await twitchEventuallyAsync { await channelResponses.count == 2 }
        await twitchEventually {
            controller.hasLoadedFollowedChannels && controller.followedChannels.isEmpty
        }

        XCTAssertTrue(settings.twitchSelectedChannelIDs(for: .allExceptSelected).isEmpty)
        XCTAssertTrue(settings.twitchSelectedChannelIDs(for: .onlySelected).isEmpty)
    }

    func testHiddenTokenSaveClearsInputWithoutReadingStoredToken() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        let session = twitchTestSession()
        let storage = TokenStorage(value: nil)
        let controller = makeController(
            settings: settings,
            authenticate: { _ in session },
            followedStreams: { _ in [] },
            sleeper: sleepForever,
            tokenStorage: storage
        )
        defer { controller.terminate() }

        _ = NSApplication.shared
        let view = TwitchNotificationView(settings: settings, controller: controller)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        XCTAssertTrue(window.isVisible)
        view.isHidden = true

        func findTokenField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField,
               field.placeholderString == "paste Twitch OAuth access token" {
                return field
            }
            for subview in view.subviews {
                if let field = findTokenField(in: subview) { return field }
            }
            return nil
        }

        let tokenField = try XCTUnwrap(findTokenField(in: view))
        tokenField.stringValue = "saved-token"
        let readCount = storage.readCount

        controller.onTokenSave?(true, "saved-token")

        XCTAssertEqual(tokenField.stringValue, "")
        XCTAssertEqual(storage.readCount, readCount)
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

private actor ControllerStreamResponses {
    private let responses: [[TwitchFollowedStream]]
    private var index = 0

    init(_ responses: [[TwitchFollowedStream]]) {
        self.responses = responses
    }

    func next() -> [TwitchFollowedStream] {
        let response = responses[min(index, responses.count - 1)]
        index += 1
        return response
    }
}

private actor ControllerFollowedChannelResponses {
    private let responses: [[TwitchFollowedChannel]]
    private var index = 0

    init(_ responses: [[TwitchFollowedChannel]]) {
        self.responses = responses
    }

    var count: Int { index }

    func next() -> [TwitchFollowedChannel] {
        let response = responses[min(index, responses.count - 1)]
        index += 1
        return response
    }
}
