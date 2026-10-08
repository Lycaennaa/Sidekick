import Foundation
import XCTest

@MainActor
final class EquicordReleaseDownloaderTests: XCTestCase {
    func testDefaultDownloaderFetchesAndValidatesRealReleaseArtifact() async throws {
        guard ProcessInfo.processInfo.environment["SIDEKICK_RUN_NETWORK_TESTS"] == "1" else {
            throw XCTSkip("Run `just test-equicord-release-network` for this live GitHub check.")
        }
        let artifact = try await EquicordReleaseDownloader().downloadLatest()
        defer { try? FileManager.default.removeItem(at: artifact.fileURL) }

        XCTAssertEqual(artifact.lifetime, .temporary)
        XCTAssertFalse(artifact.version.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.fileURL.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: artifact.fileURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(byteCount, 0)
    }
}
