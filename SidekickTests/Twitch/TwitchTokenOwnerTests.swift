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
                write: { token, _ in storage.value = token },
                delete: { storage.value = nil },
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
            .validating(token: "new", changed: true)
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
                write: { token, expected in
                    guard storage.value == expected else {
                        throw KeychainStoreError.conflict
                    }
                    storage.value = token
                },
                delete: { storage.value = nil },
                authenticate: { _ in await gate.wait() }
            )
        )
        var events: [TwitchTokenOwner.Event] = []

        XCTAssertEqual(
            owner.save("new", notificationsEnabled: true) {
                events.append($0)
                finished.fulfill()
            },
            .validating(token: "new", changed: true)
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
    func testStoredTokenStateReportsAbsentToken() {
        let owner = TwitchTokenOwner(
            dependencies: .init(
                read: { nil },
                write: { _, _ in },
                delete: {},
                authenticate: { _ in }
            )
        )

        XCTAssertEqual(owner.storedTokenState(), .absent)
    }

    func testStoredTokenStateReportsPresentToken() {
        let storage = TokenStorage(value: "saved")
        let owner = TwitchTokenOwner(
            dependencies: .init(
                read: { storage.value },
                write: { token, _ in storage.value = token },
                delete: { storage.value = nil },
                authenticate: { _ in }
            )
        )

        XCTAssertEqual(owner.storedTokenState(), .present("saved"))
    }

    func testStoredTokenStateReportsReadFailure() {
        let owner = TwitchTokenOwner(
            dependencies: .init(
                read: { throw TokenReadError() },
                write: { _, _ in },
                delete: {},
                authenticate: { _ in }
            )
        )

        XCTAssertEqual(owner.storedTokenState(), .readFailure)
    }

private struct TokenReadError: Error {}
}
