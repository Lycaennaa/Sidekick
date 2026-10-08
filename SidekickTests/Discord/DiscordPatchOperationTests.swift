import XCTest

@MainActor
final class DiscordPatchOperationTests: XCTestCase {
    func testCancellationBeforeCommitAdmissionRejectsCommit() {
        let operation = DiscordPatchOperation()

        XCTAssertTrue(operation.requestCancellation())
        XCTAssertThrowsError(try operation.admitCommit())
    }

    func testCommitAdmissionMakesLaterCancellationLose() throws {
        let operation = DiscordPatchOperation()

        try operation.admitCommit()

        XCTAssertFalse(operation.requestCancellation())
    }
}
