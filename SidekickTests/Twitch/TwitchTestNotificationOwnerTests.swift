import XCTest

@MainActor
final class TwitchTestNotificationOwnerTests: XCTestCase {
    func testTestNotificationOwnerCancellationRejectsLateProfileResult() async {
        let gate = AsyncGate()
        let notifications = NotificationRecorder()
        let testSession = twitchTestSession()
        let owner = TwitchTestNotificationOwner(
            dependencies: .init(
                storedTokenState: { .present("token") },
                authenticate: { _ in testSession },
                profileImage: { _, _ in
                    await gate.wait()
                    try Task.checkCancellation()
                    return (
                        TwitchUserProfile(
                            id: "profile",
                            login: "login",
                            displayName: "name",
                            profileImageURL: nil
                        ),
                        nil
                    )
                },
                notifications: notifications.client
            )
        )
        var profileTestDelivered = false
        var startedCount = 0
        var finishedCount = 0
        var failedCount = 0
        var cancelledCount = 0
        var rejectedCount = 0
        owner.send(username: "name", tokenSaveInProgress: false) { event in
            switch event {
            case .started:
                startedCount += 1
            case .profileTest:
                profileTestDelivered = true
            case .finished:
                finishedCount += 1
            case .failed:
                failedCount += 1
            case .cancelled:
                cancelledCount += 1
            case .rejected:
                rejectedCount += 1
            }
        }
        await twitchEventuallyAsync { await gate.hasWaiter }

        owner.cancel()
        await gate.open()
        await Task.yield()

        XCTAssertFalse(owner.isSending)
        XCTAssertFalse(profileTestDelivered)
        XCTAssertEqual(startedCount, 1)
        XCTAssertEqual(finishedCount, 0)
        XCTAssertEqual(failedCount, 0)
        XCTAssertEqual(cancelledCount, 1)
        XCTAssertEqual(rejectedCount, 0)
        XCTAssertTrue(notifications.requestIdentifiers.isEmpty)
    }

    func testTestNotificationCancellationSkipsProfileLookupAfterAuthentication() async {
        let authenticationGate = AsyncGate()
        let profileGate = AsyncGate()
        let testSession = twitchTestSession()
        let owner = TwitchTestNotificationOwner(
            dependencies: .init(
                storedTokenState: { .present("token") },
                authenticate: { _ in
                    await authenticationGate.wait()
                    return testSession
                },
                profileImage: { _, _ in
                    await profileGate.wait()
                    try Task.checkCancellation()
                    return (
                        TwitchUserProfile(
                            id: "profile",
                            login: "login",
                            displayName: "name",
                            profileImageURL: nil
                        ),
                        nil
                    )
                },
                notifications: NotificationRecorder().client
            )
        )
        var lifecycleEvents: [String] = []

        owner.send(username: "name", tokenSaveInProgress: false) { event in
            switch event {
            case .started:
                lifecycleEvents.append("started")
            case .cancelled:
                lifecycleEvents.append("cancelled")
            case .profileTest, .finished, .failed, .rejected:
                break
            }
        }
        await twitchEventuallyAsync { await authenticationGate.hasWaiter }
        owner.cancel()
        await authenticationGate.open()
        await Task.yield()

        let profileLookupStarted = await profileGate.hasWaiter
        XCTAssertFalse(profileLookupStarted)
        XCTAssertEqual(lifecycleEvents, ["started", "cancelled"])
        if profileLookupStarted {
            await profileGate.open()
        }
    }

    func testTestNotificationRejectsInvalidUsernameWithoutStarting() {
        let notifications = NotificationRecorder()
        let testSession = twitchTestSession()
        let owner = TwitchTestNotificationOwner(
            dependencies: .init(
                storedTokenState: { .present("token") },
                authenticate: { _ in testSession },
                profileImage: { _, _ in
                    (
                        TwitchUserProfile(
                            id: "unused",
                            login: "unused",
                            displayName: "unused",
                            profileImageURL: nil
                        ),
                        nil
                    )
                },
                notifications: notifications.client
            )
        )
        var events: [String] = []

        owner.send(username: "name with spaces", tokenSaveInProgress: false) { event in
            if case .rejected = event {
                events.append("rejected")
            }
        }

        XCTAssertEqual(events, ["rejected"])
        XCTAssertFalse(owner.isSending)
        XCTAssertEqual(owner.errorMessage, "enter a valid twitch username")
        XCTAssertTrue(notifications.requestIdentifiers.isEmpty)
    }

    func testTestNotificationUsesCanonicalTokenStateErrors() async {
        let cases: [(TwitchTokenOwner.StoredTokenState, String)] = [
            (.absent, "save an oauth token before testing a twitch avatar"),
            (.readFailure, "could not read oauth token from keychain")
        ]

        for (tokenState, expectedMessage) in cases {
            let testSession = twitchTestSession()
            let owner = TwitchTestNotificationOwner(
                dependencies: .init(
                    storedTokenState: { tokenState },
                    authenticate: { _ in testSession },
                    profileImage: { _, _ in
                        (
                            TwitchUserProfile(
                                id: "unused",
                                login: "unused",
                                displayName: "unused",
                                profileImageURL: nil
                            ),
                            nil
                        )
                    },
                    notifications: NotificationRecorder().client
                )
            )

            owner.send(username: "name", tokenSaveInProgress: false) { _ in }
            await twitchEventually { !owner.isSending }

            XCTAssertEqual(owner.errorMessage, expectedMessage)
        }
    }

    func testTestNotificationRejectsWhileTokenValidationIsInProgress() {
        let notifications = NotificationRecorder()
        let testSession = twitchTestSession()
        let owner = TwitchTestNotificationOwner(
            dependencies: .init(
                storedTokenState: { .present("token") },
                authenticate: { _ in testSession },
                profileImage: { _, _ in
                    (
                        TwitchUserProfile(
                            id: "unused",
                            login: "unused",
                            displayName: "unused",
                            profileImageURL: nil
                        ),
                        nil
                    )
                },
                notifications: notifications.client
            )
        )
        var events: [String] = []

        owner.send(username: "name", tokenSaveInProgress: true) { event in
            if case .rejected = event {
                events.append("rejected")
            }
        }

        XCTAssertEqual(events, ["rejected"])
        XCTAssertFalse(owner.isSending)
        XCTAssertEqual(owner.errorMessage, "wait for oauth token validation to finish")
        XCTAssertTrue(notifications.requestIdentifiers.isEmpty)
    }

    func testTestNotificationReportsAuthenticationFailure() async {
        let notifications = NotificationRecorder()
        let owner = TwitchTestNotificationOwner(
            dependencies: .init(
                storedTokenState: { .present("token") },
                authenticate: { _ in throw TwitchAPIClient.APIError.invalidToken },
                profileImage: { _, _ in
                    (
                        TwitchUserProfile(
                            id: "unused",
                            login: "unused",
                            displayName: "unused",
                            profileImageURL: nil
                        ),
                        nil
                    )
                },
                notifications: notifications.client
            )
        )
        var lifecycleEvents: [String] = []

        owner.send(username: "name", tokenSaveInProgress: false) { event in
            switch event {
            case .started:
                lifecycleEvents.append("started")
            case .failed:
                lifecycleEvents.append("failed")
            case .profileTest, .finished, .cancelled, .rejected:
                break
            }
        }

        await twitchEventually { !owner.isSending }
        XCTAssertEqual(lifecycleEvents, ["started", "failed"])
        XCTAssertEqual(owner.errorMessage, "oauth token is invalid or expired")
        XCTAssertTrue(notifications.requestIdentifiers.isEmpty)
    }

    func testProfileTestDeliversTypedPayload() async throws {
        let notifications = NotificationRecorder()
        let testSession = twitchTestSession()
        let owner = TwitchTestNotificationOwner(
            dependencies: .init(
                storedTokenState: { .present("token") },
                authenticate: { _ in testSession },
                profileImage: { _, _ in
                    (
                        TwitchUserProfile(
                            id: "profile-id",
                            login: "profile_login",
                            displayName: "Profile Name",
                            profileImageURL: nil
                        ),
                        nil
                    )
                },
                notifications: notifications.client
            )
        )
        var payload: TwitchProfileTestPayload?

        owner.send(username: "profile_login", tokenSaveInProgress: false) { event in
            if case let .profileTest(value) = event {
                payload = value
            }
        }

        await twitchEventually {
            payload != nil && notifications.requestIdentifiers == ["twitch-test-notification-1"]
        }
        let deliveredPayload = try XCTUnwrap(payload)
        XCTAssertEqual(deliveredPayload.userID, "profile-id")
        XCTAssertEqual(deliveredPayload.userLogin, "profile_login")
        XCTAssertEqual(deliveredPayload.displayName, "Profile Name")
        XCTAssertNil(deliveredPayload.imageData)
        owner.cancel()
    }

    func testTestNotificationSchedulesCanonicalTestRequest() async {
        let notifications = NotificationRecorder()
        let testSession = twitchTestSession()
        let owner = TwitchTestNotificationOwner(
            dependencies: .init(
                storedTokenState: { .absent },
                authenticate: { _ in testSession },
                profileImage: { _, _ in
                    (
                        TwitchUserProfile(
                            id: "unused",
                            login: "unused",
                            displayName: "unused",
                            profileImageURL: nil
                        ),
                        nil
                    )
                },
                notifications: notifications.client
            )
        )
        var lifecycleEvents: [String] = []
        owner.send(username: nil, tokenSaveInProgress: false) { event in
            switch event {
            case .started:
                lifecycleEvents.append("started")
            case .profileTest:
                break
            case .finished:
                lifecycleEvents.append("finished")
            case .failed, .cancelled, .rejected:
                lifecycleEvents.append("unexpected-terminal")
            }
        }

        await twitchEventually { notifications.requestIdentifiers == ["twitch-test-notification-1"] }
        await twitchEventually { !owner.isSending }
        XCTAssertEqual(lifecycleEvents, ["started", "finished"])
        owner.cancel()
    }

}
