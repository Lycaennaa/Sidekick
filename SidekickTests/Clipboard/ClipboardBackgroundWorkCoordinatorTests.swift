import Foundation
import XCTest

@MainActor
final class ClipboardBackgroundWorkCoordinatorTests: XCTestCase {
    func testPendingAndActiveCancellationUseTheirTerminalHandlers() async {
        let activeStarted = DispatchSemaphore(value: 0)
        let releaseActive = DispatchSemaphore(value: 0)
        let activeCancelled = expectation(description: "Active work cancelled")
        let pendingCancelled = expectation(description: "Pending work cancelled")
        let coordinator = ClipboardBackgroundWorkCoordinator<Int, Bool>(
            label: "ClipboardBackgroundWorkCoordinatorTests"
        )

        coordinator.enqueue(
            1,
            operation: { _, _ in
                activeStarted.signal()
                releaseActive.wait()
                return true
            },
            onResult: { _, _ in XCTFail("Cancelled work produced a result") },
            onCancelled: { work in
                XCTAssertEqual(work, 1)
                activeCancelled.fulfill()
            }
        )
        XCTAssertEqual(activeStarted.wait(timeout: .now() + 1), .success)
        coordinator.enqueue(
            2,
            operation: { _, _ in true },
            onResult: { _, _ in XCTFail("Replaced work produced a result") },
            onPendingCancelled: { work in
                XCTAssertEqual(work, 2)
                pendingCancelled.fulfill()
            }
        )
        coordinator.enqueue(
            3,
            operation: { _, _ in true },
            onResult: { _, _ in XCTFail("Cancelled pending work produced a result") }
        )

        await fulfillment(of: [pendingCancelled], timeout: 1)
        coordinator.cancelAll()
        await fulfillment(of: [activeCancelled], timeout: 1)
        releaseActive.signal()
    }
}
