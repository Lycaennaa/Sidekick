import Foundation
import XCTest

@MainActor
final class MacArtifactFileWatcherTests: XCTestCase {
    func testDefaultWatcherReportsFileCreationUnderRealWatchedRoot() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-tmp/MacArtifactFileWatcherTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let candidate = root.appendingPathComponent(".DS_Store")
        let receivedEvent = expectation(description: "FSEvents reports the created file")
        let watcher = MacArtifactFileWatcher()
        watcher.onEvents = { events in
            if events.contains(where: { $0.path == candidate.path }) {
                receivedEvent.fulfill()
            }
        }
        watcher.start(watching: [root])
        try Data([1, 2, 3]).write(to: candidate)

        await fulfillment(of: [receivedEvent], timeout: 8)
        watcher.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
    }
}
