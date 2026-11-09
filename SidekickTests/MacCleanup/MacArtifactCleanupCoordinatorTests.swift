import Foundation
import XCTest

@MainActor
final class MacArtifactCleanupCoordinatorTests: XCTestCase {
    func testFolderRootRemainsInactiveWhenStoredVolumeIdentityIsStale() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("watched-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaultsName = "MacArtifactCleanupCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        let enrollmentStore = MacArtifactCleanupStore(defaults: defaults)
        XCTAssertTrue(enrollmentStore.addFolder(folder))
        let originalRoot = try XCTUnwrap(enrollmentStore.configuration.roots.first)
        let originalIdentifier = try XCTUnwrap(originalRoot.volumeIdentifier)
        let staleRoot = MacArtifactCleanupRoot(
            id: originalRoot.id,
            path: originalRoot.path,
            kind: originalRoot.kind,
            volumeIdentifier: "replaced-\(originalIdentifier)",
            modeOverride: originalRoot.modeOverride
        )
        var staleConfiguration = MacArtifactCleanupConfiguration.initial
        staleConfiguration.roots = [staleRoot]
        defaults.set(
            try JSONEncoder().encode(staleConfiguration),
            forKey: "macArtifactCleanupConfiguration"
        )

        let store = MacArtifactCleanupStore(defaults: defaults)
        let candidate = folder.appendingPathComponent(".DS_Store")
        try Data([1, 2, 3]).write(to: candidate)
        let coordinator = MacArtifactCleanupCoordinator(store: store)
        coordinator.start()
        defer { coordinator.stop() }

        do {
            _ = try await coordinator.preview(rootID: staleRoot.id)
            XCTFail("A folder bound to another volume identity must remain inactive.")
        } catch is CancellationError {
            // Expected: the stored volume identity no longer matches this folder.
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-tmp/MacArtifactCleanupCoordinatorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
