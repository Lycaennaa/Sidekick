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
        let enrolled = await enrollmentStore.addFolder(folder)
        XCTAssertTrue(enrolled)
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

    func testFolderEnrollmentValidationRunsOffMainThread() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("watched-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaultsName = "MacArtifactCleanupCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let backgroundIdentityCalls = DispatchSemaphore(value: 0)
        let mainIdentityCalls = DispatchSemaphore(value: 0)
        let identity = MacArtifactVolumeIdentity(
            identifier: "stable-volume",
            isFuse: true,
            legacyIdentifier: nil
        )
        let store = MacArtifactCleanupStore(
            defaults: defaults,
            volumeIdentityAt: { _ in
                if Thread.isMainThread {
                    mainIdentityCalls.signal()
                } else {
                    backgroundIdentityCalls.signal()
                }
                return identity
            }
        )

        let added = await store.addFolder(folder)

        XCTAssertTrue(added)
        XCTAssertEqual(store.configuration.roots.first?.volumeIdentifier, "stable-volume")
        XCTAssertEqual(backgroundIdentityCalls.wait(timeout: .now()), .success)
        XCTAssertEqual(mainIdentityCalls.wait(timeout: .now()), .success)
        XCTAssertEqual(backgroundIdentityCalls.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(mainIdentityCalls.wait(timeout: .now()), .timedOut)

    }


    func testFolderEnrollmentRejectsIdentityReplacedDuringValidation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("watched-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaultsName = "MacArtifactCleanupCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = MacArtifactCleanupStore(
            defaults: defaults,
            volumeIdentityAt: { _ in
                MacArtifactVolumeIdentity(
                    identifier: Thread.isMainThread ? "replacement-volume" : "validated-volume",
                    isFuse: true,
                    legacyIdentifier: nil
                )
            }
        )

        let added = await store.addFolder(folder)

        XCTAssertFalse(added)
        XCTAssertTrue(store.configuration.roots.isEmpty)
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
