import AppKit
import Foundation
import XCTest

@MainActor
final class TwitchKeychainAccessTests: TwitchNotificationControllerTestSupport {
    func testKeychainAccessPromptsAtStartupAndSettingsButtonOnce() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.twitchNotificationsEnabled = true
        let session = twitchTestSession()
        let tokenReadRecorder = KeychainReadRecorder(fails: true)
        let promptRecorder = KeychainPromptRecorder()
        let controller = makeController(
            settings: settings,
            authenticate: { _ in session },
            followedStreams: { _ in [] },
            sleeper: sleepForever,
            tokenRead: { try tokenReadRecorder.read() },
            keychainAccessRequest: {
                await promptRecorder.record()
                throw KeychainReadFailure()
            }
        )
        defer { controller.terminate() }

        await controller.requestKeychainAccessAtStartup()
        await controller.requestKeychainAccessAtStartup()
        XCTAssertEqual(tokenReadRecorder.count, 0)
        for _ in 0..<3 {
            XCTAssertEqual(controller.oauthTokenState, .readFailure)
        }
        XCTAssertEqual(tokenReadRecorder.count, 0)
        let startupPromptCount = await promptRecorder.count
        XCTAssertEqual(startupPromptCount, 1)
        XCTAssertTrue(controller.canPromptForKeychainAccess)

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
        view.refresh()

        let promptButton = try XCTUnwrap(findPromptButton(in: view))
        XCTAssertFalse(promptButton.isHidden)
        XCTAssertTrue(promptButton.isEnabled)

        let promptFinished = expectation(description: "Manual Keychain prompt finished")
        var didObservePromptCompletion = false
        controller.onStateChange = {
            guard !controller.isRequestingKeychainAccess, !didObservePromptCompletion else { return }
            didObservePromptCompletion = true
            promptFinished.fulfill()
        }
        promptButton.performClick(nil)
        await fulfillment(of: [promptFinished], timeout: 2)
        view.refresh()

        let totalPromptCount = await promptRecorder.count
        XCTAssertEqual(totalPromptCount, 2)
        XCTAssertFalse(promptButton.isEnabled)
        promptButton.performClick(nil)
        let finalPromptCount = await promptRecorder.count
        XCTAssertEqual(finalPromptCount, 2)
    }

    func testKeychainPromptLeavesMainActorResponsiveAndShowsPendingState() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        let session = twitchTestSession()
        let promptStarted = expectation(description: "Keychain prompt started")
        let gate = AsyncGate()
        let controller = makeController(
            settings: settings,
            authenticate: { _ in session },
            followedStreams: { _ in [] },
            sleeper: sleepForever,
            keychainAccessRequest: {
                promptStarted.fulfill()
                await gate.wait()
                return nil
            }
        )
        defer { controller.terminate() }

        var stateChangeCount = 0
        controller.onStateChange = { stateChangeCount += 1 }
        let startupRequest = Task { await controller.requestKeychainAccessAtStartup() }
        await fulfillment(of: [promptStarted], timeout: 2)
        XCTAssertTrue(controller.isRequestingKeychainAccess)
        XCTAssertEqual(controller.oauthTokenState, .loading)
        _ = NSApplication.shared
        let view = TwitchNotificationView(settings: settings, controller: controller)
        view.refresh()
        let promptButton = try XCTUnwrap(findPromptButton(in: view))
        XCTAssertTrue(promptButton.isHidden)
        settings.twitchNotificationsEnabled = true
        controller.applySettings()
        XCTAssertTrue(settings.twitchNotificationsEnabled)
        controller.terminate()
        let changesAtTermination = stateChangeCount
        await gate.open()
        await startupRequest.value

        XCTAssertEqual(stateChangeCount, changesAtTermination)
        XCTAssertFalse(controller.isRequestingKeychainAccess)
    }

    func testSuccessfulStartupPromptHandsTokenToPollingWithoutReread() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        let session = twitchTestSession()
        let promptRecorder = KeychainPromptRecorder()
        let tokenReadRecorder = KeychainReadRecorder(fails: false)
        let authenticationFinished = expectation(description: "Polling authenticated with prompted token")
        let authenticationRecorder = AuthenticationTokenRecorder(expectation: authenticationFinished)
        let controller = makeController(
            settings: settings,
            authenticate: { token in
                await authenticationRecorder.record(token)
                return session
            },
            followedStreams: { _ in [] },
            sleeper: sleepForever,
            tokenRead: { try tokenReadRecorder.read() },
            keychainAccessRequest: {
                await promptRecorder.record()
                return "prompted-token"
            }
        )
        defer { controller.terminate() }

        await controller.requestKeychainAccessAtStartup()
        XCTAssertEqual(controller.oauthTokenState, .present("prompted-token"))
        XCTAssertEqual(tokenReadRecorder.count, 0)
        settings.twitchNotificationsEnabled = true
        controller.applySettings()
        await fulfillment(of: [authenticationFinished], timeout: 2)

        XCTAssertEqual(authenticationRecorder.token, "prompted-token")
        XCTAssertEqual(controller.oauthTokenState, .present("prompted-token"))
        XCTAssertEqual(tokenReadRecorder.count, 0)
        let promptCount = await promptRecorder.count
        XCTAssertEqual(promptCount, 1)
    }

    func testValidationFailureReconcilesNewerKeychainTokenForPolling() async {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.twitchNotificationsEnabled = true
        let storage = TokenStorage(value: "old-token")
        let session = twitchTestSession()
        let oldTokenAuthenticated = expectation(description: "Old token started polling")
        let candidateValidationStarted = expectation(description: "Candidate token validation started")
        let newerTokenAuthenticated = expectation(description: "Newer token replaced polling credentials")
        let validationGate = AsyncGate()
        let controller = makeController(
            settings: settings,
            authenticate: { token in
                switch token {
                case "old-token":
                    oldTokenAuthenticated.fulfill()
                case "newer-token":
                    newerTokenAuthenticated.fulfill()
                default:
                    throw TwitchAPIClient.APIError.invalidToken
                }
                return session
            },
            tokenAuthenticate: { token in
                guard token == "candidate-token" else {
                    throw TwitchAPIClient.APIError.invalidToken
                }
                candidateValidationStarted.fulfill()
                await validationGate.wait()
                throw TwitchAPIClient.APIError.invalidToken
            },
            followedStreams: { _ in [] },
            sleeper: sleepForever,
            tokenStorage: storage
        )
        defer { controller.terminate() }

        controller.applySettings()
        await fulfillment(of: [oldTokenAuthenticated], timeout: 2)
        XCTAssertTrue(controller.saveOAuthToken("candidate-token"))
        await fulfillment(of: [candidateValidationStarted], timeout: 2)
        storage.value = "newer-token"
        await validationGate.open()
        await fulfillment(of: [newerTokenAuthenticated], timeout: 2)

        XCTAssertEqual(controller.oauthTokenState, .present("newer-token"))
        XCTAssertEqual(storage.value, "newer-token")
    }

    func testManualPromptResultSurvivesOAuthSaveDuringPrompt() async throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.twitchOAuthClientID = "existing-client-id"
        let tokenStorage = TokenStorage(value: "existing-token")
        let tokenReadRecorder = KeychainReadRecorder(fails: true)
        let promptRecorder = KeychainPromptRecorder()
        let manualPromptStarted = expectation(description: "Manual prompt is pending")
        let tokenSaved = expectation(description: "Queued OAuth token was saved")
        let gate = AsyncGate()
        let session = twitchTestSession()
        let controller = makeController(
            settings: settings,
            authenticate: { _ in session },
            followedStreams: { _ in [] },
            sleeper: sleepForever,
            tokenStorage: tokenStorage,
            tokenRead: { try tokenReadRecorder.read() },
            keychainAccessRequest: {
                if await promptRecorder.recordAndReturnCount() == 1 {
                    throw KeychainReadFailure()
                }
                manualPromptStarted.fulfill()
                await gate.wait()
                return "existing-token"
            }
        )
        defer { controller.terminate() }
        let controls = try makeKeychainPromptControlSet(settings: settings, controller: controller)
        controller.onStateChange = { [weak view = controls.view] in view?.refresh() }
        controller.onTokenSave = { success, token in
            if token == "queued-token" {
                XCTAssertTrue(success)
                tokenSaved.fulfill()
            }
        }

        await controller.requestKeychainAccessAtStartup()
        XCTAssertEqual(controller.oauthTokenState, .readFailure)
        let manualPrompt = Task { await controller.promptForKeychainAccess() }
        await fulfillment(of: [manualPromptStarted], timeout: 2)
        assertPromptControlsDisabled(controls)

        XCTAssertTrue(controller.saveOAuthToken("queued-token"))
        XCTAssertFalse(controller.isSavingOAuthToken)
        await gate.open()
        await manualPrompt.value
        await fulfillment(of: [tokenSaved], timeout: 2)

        XCTAssertEqual(controller.oauthTokenState, .present("queued-token"))
        XCTAssertEqual(tokenReadRecorder.count, 0)
        let promptCount = await promptRecorder.count
        XCTAssertEqual(promptCount, 2)
    }
    private func findPromptButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == "Prompt Keychain" {
            return button
        }
        return view.subviews.lazy.compactMap { self.findPromptButton(in: $0) }.first
    }

    private func findSaveTokenButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == "Save Token" { return button }
        return view.subviews.lazy.compactMap { self.findSaveTokenButton(in: $0) }.first
    }

    private func findOAuthTokenField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField,
           field.placeholderString == "paste Twitch OAuth access token" { return field }
        return view.subviews.lazy.compactMap { self.findOAuthTokenField(in: $0) }.first
    }
}

private struct OAuthClientControls {
    let clientIDField: NSTextField
    let saveClientIDButton: NSButton
    let clearClientIDButton: NSButton
    let usernameField: NSTextField
}

@MainActor
private func makeOAuthClientControls(in view: NSView) throws -> OAuthClientControls {
    OAuthClientControls(
        clientIDField: try XCTUnwrap(findTextField(in: view, placeholder: "Twitch OAuth client ID")),
        saveClientIDButton: try XCTUnwrap(findButton(in: view, title: "Save ID")),
        clearClientIDButton: try XCTUnwrap(findButton(in: view, title: "Use App/Source")),
        usernameField: try XCTUnwrap(findTextField(in: view, placeholder: "Twitch username"))
    )
}

@MainActor
private func findTextField(in view: NSView, placeholder: String) -> NSTextField? {
    if let field = view as? NSTextField, field.placeholderString == placeholder { return field }
    return view.subviews.lazy.compactMap { findTextField(in: $0, placeholder: placeholder) }.first
}

@MainActor
private func findButton(in view: NSView, title: String) -> NSButton? {
    if let button = view as? NSButton, button.title == title { return button }
    return view.subviews.lazy.compactMap { findButton(in: $0, title: title) }.first
}

private struct KeychainPromptControls {
    let view: TwitchNotificationView
    let tokenField: NSTextField
    let saveTokenButton: NSButton
    let oauthClientIDField: NSTextField
    let saveClientIDButton: NSButton
    let clearClientIDButton: NSButton
    let usernameField: NSTextField
    let getOAuthTokenButton: NSButton
    let browserFallbackButton: NSButton
    let testNotificationButton: NSButton
}

@MainActor
private func makeKeychainPromptControlSet(
    settings: AppSettings,
    controller: TwitchNotificationController
) throws -> KeychainPromptControls {
    _ = NSApplication.shared
    let view = TwitchNotificationView(settings: settings, controller: controller)
    view.refresh()
    let tokenField = try XCTUnwrap(findTextField(in: view, placeholder: "paste Twitch OAuth access token"))
    tokenField.stringValue = "queued-token"
    let oauthClientIDField = try XCTUnwrap(findTextField(in: view, placeholder: "Twitch OAuth client ID"))
    oauthClientIDField.stringValue = "new-client-id"
    view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: tokenField))
    view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: oauthClientIDField))
    let controls = KeychainPromptControls(
        view: view,
        tokenField: tokenField,
        saveTokenButton: try XCTUnwrap(findButton(in: view, title: "Save Token")),
        oauthClientIDField: oauthClientIDField,
        saveClientIDButton: try XCTUnwrap(findButton(in: view, title: "Save ID")),
        clearClientIDButton: try XCTUnwrap(findButton(in: view, title: "Use App/Source")),
        usernameField: try XCTUnwrap(findTextField(in: view, placeholder: "Twitch username")),
        getOAuthTokenButton: try XCTUnwrap(findButton(in: view, title: "Get Token from Twitch")),
        browserFallbackButton: try XCTUnwrap(findButton(in: view, title: "Use Browser Fallback")),
        testNotificationButton: try XCTUnwrap(findButton(in: view, title: "Send Test Notification"))
    )
    XCTAssertTrue(controls.tokenField.isEnabled)
    XCTAssertTrue(controls.saveTokenButton.isEnabled)
    XCTAssertTrue(controls.oauthClientIDField.isEnabled)
    XCTAssertTrue(controls.saveClientIDButton.isEnabled)
    XCTAssertTrue(controls.clearClientIDButton.isEnabled)
    XCTAssertTrue(controls.usernameField.isEnabled)
    XCTAssertTrue(controls.getOAuthTokenButton.isEnabled)
    XCTAssertTrue(controls.browserFallbackButton.isEnabled)
    return controls
}

@MainActor
private func assertPromptControlsDisabled(_ controls: KeychainPromptControls) {
    XCTAssertFalse(controls.tokenField.isEnabled)
    XCTAssertFalse(controls.saveTokenButton.isEnabled)
    XCTAssertFalse(controls.oauthClientIDField.isEnabled)
    XCTAssertFalse(controls.saveClientIDButton.isEnabled)
    XCTAssertFalse(controls.clearClientIDButton.isEnabled)
    XCTAssertFalse(controls.usernameField.isEnabled)
    XCTAssertFalse(controls.getOAuthTokenButton.isEnabled)
    XCTAssertFalse(controls.browserFallbackButton.isEnabled)
    XCTAssertFalse(controls.testNotificationButton.isEnabled)
    controls.view.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: controls.tokenField)
    )
    controls.view.controlTextDidChange(
        Notification(name: NSControl.textDidChangeNotification, object: controls.oauthClientIDField)
    )
    XCTAssertFalse(controls.saveTokenButton.isEnabled)
    XCTAssertFalse(controls.saveClientIDButton.isEnabled)
    XCTAssertFalse(controls.clearClientIDButton.isEnabled)
}

private actor KeychainPromptRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
    func recordAndReturnCount() -> Int {
        count += 1
        return count
    }
}

@MainActor
private final class KeychainReadRecorder {
    private(set) var count = 0
    private let fails: Bool

    init(fails: Bool) {
        self.fails = fails
    }

    func read() throws -> String? {
        count += 1
        if fails { throw KeychainReadFailure() }
        return nil
    }
}

@MainActor
private final class AuthenticationTokenRecorder {
    private(set) var token: String?
    private let expectation: XCTestExpectation

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func record(_ token: String) {
        self.token = token
        expectation.fulfill()
    }
}

private struct KeychainReadFailure: Error {}
