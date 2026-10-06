import XCTest

final class KeychainStoreTests: XCTestCase {
    func testRoundTripUsesDefaultKeychainStore() throws {
        let account = "test.twitch.access-token.\(UUID().uuidString)"
        let store = KeychainStore()
        defer {
            do {
                try store.delete(account: account)
            } catch {
                XCTFail("Keychain cleanup failed: \(error)")
            }
        }

        try store.write("first-token", replacing: nil, account: account)
        try store.write("second-token", replacing: "first-token", account: account)

        let competingStore = KeychainStore()
        try competingStore.write("newer-token", replacing: "second-token", account: account)
        XCTAssertThrowsError(
            try store.write("stale-token", replacing: "second-token", account: account)
        ) { error in
            XCTAssertEqual(error as? KeychainStoreError, .conflict)
        }
        XCTAssertEqual(try store.read(account: account), "newer-token")
    }
}
