import XCTest

@MainActor
final class TwitchTokenOwnerTests: XCTestCase {
    func testTokenOwnerCancellationRejectsLateValidation() async {
        let gate = AsyncGate()
        let completion = AsyncGate()
        let completionWaiter = Task { await completion.wait() }
        await completion.waitUntilWaiterAttached()
        let storage = TokenStorage(value: "old")
        let owner = TwitchTokenOwner(
            dependencies: .init(
                read: { storage.value },
                write: { token, _, _ in storage.value = token },
                delete: { expected, _ in
                    guard storage.value == expected else { throw KeychainStoreError.conflict }
                    storage.value = nil
                },
                authenticate: { _ in
                    await gate.wait()
                    if Task.isCancelled {
                        await completion.open()
                        throw CancellationError()
                    }
                    await completion.open()
                }
            )
        )
        var events: [TwitchTokenOwner.Event] = []

        XCTAssertEqual(
            owner.save("new", notificationsEnabled: true) { events.append($0) },
            .validating(token: "new")
        )
        await gate.waitUntilWaiterAttached()
        owner.cancel()
        await gate.open()
        await completionWaiter.value

        XCTAssertEqual(storage.value, "old")
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(owner.isSaving)
    }

    func testTokenOwnerKeepsNewerTokenAfterValidation() async {
        let gate = AsyncGate()
        let storage = TokenStorage(value: "old")
        let finished = expectation(description: "Token validation finished")
        let owner = TwitchTokenOwner(
            dependencies: .init(
                read: { storage.value },
                write: { token, expected, _ in
                    guard storage.value == expected else {
                        throw KeychainStoreError.conflict
                    }
                    storage.value = token
                },
                delete: { expected, _ in
                    guard storage.value == expected else { throw KeychainStoreError.conflict }
                    storage.value = nil
                },
                authenticate: { _ in await gate.wait() }
            )
        )
        var events: [TwitchTokenOwner.Event] = []

        XCTAssertEqual(
            owner.save("new", notificationsEnabled: true) {
                events.append($0)
                finished.fulfill()
            },
            .validating(token: "new")
        )
        await gate.waitUntilWaiterAttached()
        storage.value = "newer"
        await gate.open()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(storage.value, "newer")
        XCTAssertEqual(
            events,
            [.failed(
                token: "new",
                message: "oauth token changed while validation was running; newer token kept"
            )]
        )
        XCTAssertFalse(owner.isSaving)
    }

    func testAuthenticationFailureRefreshesNewerStoredToken() async {
        let authenticationGate = AsyncGate()
        let storage = TokenStorage(value: "old-token")
        let authenticationFinished = expectation(description: "Token authentication failure handled")
        let owner = TwitchTokenOwner(
            dependencies: .init(
                read: { storage.value },
                write: { _, _, _ in throw KeychainStoreError.conflict },
                delete: { expected, _ in
                    guard storage.value == expected else { throw KeychainStoreError.conflict }
                    storage.value = nil
                },
                authenticate: { _ in
                    await authenticationGate.wait()
                    throw TwitchAPIClient.APIError.invalidToken
                }
            )
        )
        var events: [TwitchTokenOwner.Event] = []

        XCTAssertEqual(
            owner.save("candidate-token", notificationsEnabled: true) {
                events.append($0)
                authenticationFinished.fulfill()
            },
            .validating(token: "candidate-token")
        )
        await authenticationGate.waitUntilWaiterAttached()
        storage.value = "newer-token"
        await authenticationGate.open()
        await fulfillment(of: [authenticationFinished], timeout: 2)

        XCTAssertEqual(storage.value, "newer-token")
        XCTAssertEqual(owner.storedTokenState(), .present("newer-token"))
        XCTAssertEqual(
            events,
            [.failed(token: "candidate-token", message: "new oauth token is invalid; existing token kept")]
        )
    }

    func testCancelledPendingKeychainWriteDoesNotCommit() async throws {
        let account = "test.twitch.cancelled-write.\(UUID().uuidString)"
        let store = KeychainStore()
        addTeardownBlock {
            try await store.delete(account: account)
        }
        try await store.write("old-token", replacing: nil, account: account)

        let writeStarted = expectation(description: "Keychain write was requested")
        let queueBlockStarted = expectation(description: "Keychain executor is blocked")
        let releaseSecurityQueue = DispatchSemaphore(value: 0)
        defer { releaseSecurityQueue.signal() }
        let writeFinished = AsyncGate()
        let writeFinishedWaiter = Task { await writeFinished.wait() }
        await writeFinished.waitUntilWaiterAttached()
        let owner = TwitchTokenOwner(
            dependencies: .init(
                read: { try await store.read(account: account) },
                write: { token, expectedValue, authorization in
                    KeychainStore.keychainInteractionQueue.async {
                        queueBlockStarted.fulfill()
                        releaseSecurityQueue.wait()
                    }
                    writeStarted.fulfill()
                    do {
                        try await store.write(
                            token,
                            replacing: expectedValue,
                            account: account,
                            authorization: authorization
                        )
                        await writeFinished.open()
                    } catch {
                        await writeFinished.open()
                        throw error
                    }
                },
                delete: { expectedToken, authorization in
                    try await store.delete(
                        account: account,
                        ifValueIs: expectedToken,
                        authorization: authorization
                    )
                },
                authenticate: { _ in }
            )
        )
        var events: [TwitchTokenOwner.Event] = []

        XCTAssertEqual(
            owner.save("new-token", notificationsEnabled: true) { events.append($0) },
            .validating(token: "new-token")
        )
        await fulfillment(of: [writeStarted, queueBlockStarted], timeout: 2)
        owner.cancel()
        releaseSecurityQueue.signal()
        await writeFinishedWaiter.value

        let storedToken = try await store.read(account: account)
        XCTAssertEqual(storedToken, "old-token")
        XCTAssertTrue(events.isEmpty)
    }

    func testCancelledPendingKeychainDeleteDoesNotCommit() async throws {
        let account = "test.twitch.cancelled-delete.\(UUID().uuidString)"
        let store = KeychainStore()
        addTeardownBlock {
            try await store.delete(account: account)
        }
        try await store.write("saved-token", replacing: nil, account: account)

        let deleteStarted = expectation(description: "Keychain delete was requested")
        let queueBlockStarted = expectation(description: "Keychain executor is blocked")
        let releaseSecurityQueue = DispatchSemaphore(value: 0)
        defer { releaseSecurityQueue.signal() }
        let deleteFinished = AsyncGate()
        let deleteFinishedWaiter = Task { await deleteFinished.wait() }
        await deleteFinished.waitUntilWaiterAttached()
        let owner = TwitchTokenOwner(
            dependencies: .init(
                read: { try await store.read(account: account) },
                write: { token, expectedValue, authorization in
                    try await store.write(
                        token,
                        replacing: expectedValue,
                        account: account,
                        authorization: authorization
                    )
                },
                delete: { expectedToken, authorization in
                    KeychainStore.keychainInteractionQueue.async {
                        queueBlockStarted.fulfill()
                        releaseSecurityQueue.wait()
                    }
                    deleteStarted.fulfill()
                    do {
                        try await store.delete(
                            account: account,
                            ifValueIs: expectedToken,
                            authorization: authorization
                        )
                        await deleteFinished.open()
                    } catch {
                        await deleteFinished.open()
                        throw error
                    }
                },
                authenticate: { _ in }
            )
        )
        var didComplete = false

        let tokenStateReady = expectation(description: "Stored token state is ready for removal")
        owner.refreshStoredTokenState { _ in tokenStateReady.fulfill() }
        await fulfillment(of: [tokenStateReady], timeout: 2)
        owner.remove { _ in didComplete = true }
        await fulfillment(of: [deleteStarted, queueBlockStarted], timeout: 2)
        owner.cancel()
        releaseSecurityQueue.signal()
        await deleteFinishedWaiter.value

        let storedToken = try await store.read(account: account)
        XCTAssertEqual(storedToken, "saved-token")
        XCTAssertFalse(didComplete)
    }

    func testWriteConflictRefreshesNewerStoredTokenState() async {
        let storage = TokenStorage(value: "old-token")
        let completed = expectation(description: "Save conflict reconciled")
        let owner = TwitchTokenOwner(
            dependencies: .init(
                read: { storage.value },
                write: { _, expected, _ in
                    guard storage.value == expected else {
                        throw KeychainStoreError.conflict
                    }
                    storage.value = "newer-token"
                    throw KeychainStoreError.conflict
                },
                delete: { expected, _ in
                    guard storage.value == expected else { throw KeychainStoreError.conflict }
                    storage.value = nil
                },
                authenticate: { _ in }
            )
        )
        var events: [TwitchTokenOwner.Event] = []

        XCTAssertEqual(
            owner.save("candidate-token", notificationsEnabled: true) {
                events.append($0)
                completed.fulfill()
            },
            .validating(token: "candidate-token")
        )
        await fulfillment(of: [completed], timeout: 2)

        XCTAssertEqual(storage.value, "newer-token")
        XCTAssertEqual(owner.storedTokenState(), .present("newer-token"))
        let expectedEvent = TwitchTokenOwner.Event.failed(
            token: "candidate-token",
            message: "oauth token changed while validation was running; newer token kept"
        )
        XCTAssertEqual(events, [expectedEvent])
    }
    func testStoredTokenStateReportsAbsentToken() async {
        let owner = TwitchTokenOwner(
            dependencies: .init(
                read: { nil },
                write: { _, _, _ in },
                delete: { _, _ in },
                authenticate: { _ in }
            )
        )

        let readFinished = expectation(description: "Stored token read finished")
        owner.refreshStoredTokenState { _ in readFinished.fulfill() }
        await fulfillment(of: [readFinished], timeout: 1)
        XCTAssertEqual(owner.storedTokenState(), .absent)
    }

    func testStoredTokenStateReportsPresentToken() async {
        let storage = TokenStorage(value: "saved")
        let owner = TwitchTokenOwner(
            dependencies: .init(
                read: { storage.value },
                write: { token, _, _ in storage.value = token },
                delete: { expected, _ in
                    guard storage.value == expected else { throw KeychainStoreError.conflict }
                    storage.value = nil
                },
                authenticate: { _ in }
            )
        )

        let readFinished = expectation(description: "Stored token read finished")
        owner.refreshStoredTokenState { _ in readFinished.fulfill() }
        await fulfillment(of: [readFinished], timeout: 1)
        XCTAssertEqual(owner.storedTokenState(), .present("saved"))
    }

    func testStoredTokenStateReportsReadFailure() async {
        let owner = TwitchTokenOwner(
            dependencies: .init(
                read: { throw TokenReadError() },
                write: { _, _, _ in },
                delete: { _, _ in },
                authenticate: { _ in }
            )
        )

        let readFinished = expectation(description: "Stored token read finished")
        owner.refreshStoredTokenState { _ in readFinished.fulfill() }
        await fulfillment(of: [readFinished], timeout: 1)
        XCTAssertEqual(owner.storedTokenState(), .readFailure)
    }

private struct TokenReadError: Error {}
}
