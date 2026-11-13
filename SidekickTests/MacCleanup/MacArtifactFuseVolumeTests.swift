import Foundation
import XCTest

@MainActor
final class MacArtifactFuseVolumeTests: XCTestCase {
    func testFuseIdentityIsStableForTheSameMountSourceAndRecognizesCustomTypes() throws {
        XCTAssertTrue(MacArtifactCleanupRoot.isFuseFileSystem("macfuse_sshfs"))
        XCTAssertTrue(MacArtifactCleanupRoot.isFuseFileSystem("osxfuse_sshfs"))
        XCTAssertFalse(MacArtifactCleanupRoot.isFuseFileSystem("nfs"))

        let identity = try XCTUnwrap(
            MacArtifactCleanupRoot.fuseIdentifier(
                type: "macfuse_sshfs",
                source: "sshfs#user@example.test:/data",
                mountPoint: "/Volumes/remote"
            )
        )
        let remountedIdentity = MacArtifactCleanupRoot.fuseIdentifier(
            type: "macfuse_sshfs",
            source: "sshfs#user@example.test:/data",
            mountPoint: "/Volumes/remote"
        )
        let replacementIdentity = MacArtifactCleanupRoot.fuseIdentifier(
            type: "macfuse_sshfs",
            source: "sshfs#user@example.test:/other",
            mountPoint: "/Volumes/remote"
        )
        XCTAssertEqual(identity, remountedIdentity)
        XCTAssertNotEqual(identity, replacementIdentity)
        XCTAssertNil(
            MacArtifactCleanupRoot.fuseIdentifier(
                type: "macfuse_sshfs",
                source: "",
                mountPoint: "/Volumes/remote"
            )
        )
    }
    func testCurrentFuseIdentityUsesSourceNotMountGeneratedUUID() throws {
        let firstMount = try XCTUnwrap(
            MacArtifactCleanupRoot.resolveVolumeIdentity(
                volumeUUIDString: "mount-uuid-1",
                fileSystemType: "macfuse_sshfs",
                source: "sshfs#user@example.test:/data",
                mountPoint: "/Volumes/remote"
            )
        )
        let remount = try XCTUnwrap(
            MacArtifactCleanupRoot.resolveVolumeIdentity(
                volumeUUIDString: "mount-uuid-2",
                fileSystemType: "macfuse_sshfs",
                source: "sshfs#user@example.test:/data",
                mountPoint: "/Volumes/remote"
            )
        )

        XCTAssertEqual(firstMount.identifier, remount.identifier)
        XCTAssertNotEqual(firstMount.identifier, firstMount.legacyIdentifier)
        XCTAssertEqual(firstMount.legacyIdentifier, "mount-uuid-1")
        XCTAssertEqual(remount.legacyIdentifier, "mount-uuid-2")
    }

    func testLegacyFuseIdentityMigratesOnlyForMatchingMountedVolumeUUID() throws {
        let identity = try XCTUnwrap(
            MacArtifactCleanupRoot.resolveVolumeIdentity(
                volumeUUIDString: "mount-uuid-1",
                fileSystemType: "macfuse",
                source: "sshfs#user@example.test:/data",
                mountPoint: "/Volumes/remote"
            )
        )
        var enrolledRoot = MacArtifactCleanupRoot(
            id: UUID(),
            path: "/Volumes/remote/Photos",
            kind: .folder,
            volumeIdentifier: "mount-uuid-1",
            modeOverride: nil
        )
        XCTAssertTrue(enrolledRoot.migrateLegacyFuseVolumeIdentifier(using: identity))
        XCTAssertEqual(enrolledRoot.volumeIdentifier, identity.identifier)

        let remountedIdentity = try XCTUnwrap(
            MacArtifactCleanupRoot.resolveVolumeIdentity(
                volumeUUIDString: "mount-uuid-2",
                fileSystemType: "macfuse",
                source: "sshfs#user@example.test:/data",
                mountPoint: "/Volumes/remote"
            )
        )
        var staleRoot = MacArtifactCleanupRoot(
            id: UUID(),
            path: "/Volumes/remote/Photos",
            kind: .folder,
            volumeIdentifier: "mount-uuid-1",
            modeOverride: nil
        )
        XCTAssertFalse(staleRoot.migrateLegacyFuseVolumeIdentifier(using: remountedIdentity))
        XCTAssertEqual(staleRoot.volumeIdentifier, "mount-uuid-1")
    }

    func testMountedFuseVolumeSupportsFolderAndAutomaticEnrollment() async throws {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [],
            options: []
        ) ?? []
        guard let volume = volumes.first(where: {
            MacArtifactCleanupRoot.currentVolumeIdentity(at: $0)?.isFuse == true
        }) else {
            throw XCTSkip("A mounted FUSE filesystem is required for this integration test.")
        }
        let identity = try XCTUnwrap(MacArtifactCleanupRoot.currentVolumeIdentity(at: volume))
        let suiteName = "MacArtifactFuseVolumeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MacArtifactCleanupStore(defaults: defaults)
        let coordinator = MacArtifactCleanupCoordinator(store: store)
        var enrollmentRequested = false
        coordinator.onRequestEnrollment = { requestedVolume in
            if requestedVolume.identifier == identity.identifier {
                enrollmentRequested = true
            }
        }
        coordinator.start()
        defer { coordinator.stop() }
        XCTAssertTrue(enrollmentRequested)
        let addedFolder = await store.addFolder(volume)
        XCTAssertTrue(addedFolder)
        XCTAssertTrue(
            MacArtifactVolumeMonitor().mountedExternalVolumes().contains {
                $0.url.standardizedFileURL == volume.standardizedFileURL
                    && $0.identifier == identity.identifier
            }
        )
    }
}
