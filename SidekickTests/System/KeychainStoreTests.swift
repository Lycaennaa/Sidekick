import XCTest

final class KeychainStoreTests: XCTestCase {
    func testRoundTripUsesDefaultKeychainStore() async throws {
        let account = "test.twitch.access-token.\(UUID().uuidString)"
        let store = KeychainStore()
        addTeardownBlock {
            try await store.delete(account: account)
        }

        try await store.write("first-token", replacing: nil, account: account)
        try await store.write("second-token", replacing: "first-token", account: account)

        let competingStore = KeychainStore()
        try await competingStore.write("newer-token", replacing: "second-token", account: account)
        do {
            try await store.write("stale-token", replacing: "second-token", account: account)
            XCTFail("Expected stale write to conflict")
        } catch {
            XCTAssertEqual(error as? KeychainStoreError, .conflict)
        }
        let promptedToken = try await store.promptForAccess(account: account)
        XCTAssertEqual(promptedToken, "newer-token")
        let readToken = try await store.read(account: account)
        XCTAssertEqual(readToken, "newer-token")
    }

    func testCancelledAuthorizationAtMutationBoundaryPreservesExistingItem() async throws {
        let account = "test.twitch.cancelled-boundary.\(UUID().uuidString)"
        let store = KeychainStore()
        addTeardownBlock {
            try await store.delete(account: account)
        }
        try await store.write("existing-token", replacing: nil, account: account)

        let mutationBoundaryReached = expectation(description: "Serialized mutation boundary reached")
        let releaseMutation = DispatchSemaphore(value: 0)
        var didReleaseMutation = false
        defer {
            if !didReleaseMutation { releaseMutation.signal() }
        }
        let authorization = KeychainMutationAuthorization {
            mutationBoundaryReached.fulfill()
            releaseMutation.wait()
        }
        let writeTask = Task {
            do {
                try await store.write(
                    "stale-token",
                    replacing: "existing-token",
                    account: account,
                    authorization: authorization
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await fulfillment(of: [mutationBoundaryReached], timeout: 2)

        authorization.cancel()
        releaseMutation.signal()
        didReleaseMutation = true
        let rejected = await writeTask.value
        let storedToken = try await store.read(account: account)

        XCTAssertTrue(rejected)
        XCTAssertEqual(storedToken, "existing-token")
    }

    func testStaleDeletePreservesNewerKeychainItem() async throws {
        let account = "test.twitch.stale-delete.\(UUID().uuidString)"
        let store = KeychainStore()
        addTeardownBlock {
            try await store.delete(account: account)
        }
        try await store.write("old-token", replacing: nil, account: account)
        try await store.write("newer-token", replacing: "old-token", account: account)

        do {
            try await store.delete(account: account, ifValueIs: "old-token")
            XCTFail("Expected stale delete to conflict")
        } catch {
            XCTAssertEqual(error as? KeychainStoreError, .conflict)
        }

        let storedToken = try await store.read(account: account)
        XCTAssertEqual(storedToken, "newer-token")
    }
}
