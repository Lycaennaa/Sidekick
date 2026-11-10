import XCTest

@MainActor
final class MacArtifactCleanupStoreTests: XCTestCase {
    func testRootModesPersistWithGlobalDefaultAndPerRootOverride() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MacArtifactCleanupStore(defaults: defaults)
        XCTAssertEqual(store.configuration.defaultMode, .deletePermanently)
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-tmp/MacArtifactCleanupStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("Photos", isDirectory: true)
        let secondURL = directory.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)

        let addedFirstFolder = await store.addFolder(firstURL)
        XCTAssertTrue(addedFirstFolder)
        let addedSecondFolder = await store.addFolder(secondURL)
        XCTAssertTrue(addedSecondFolder)
        let firstRoot = try XCTUnwrap(store.configuration.roots.first)
        XCTAssertEqual(
            firstRoot.volumeIdentifier,
            MacArtifactCleanupRoot.currentVolumeIdentifier(at: firstURL)
        )
        let secondRoot = try XCTUnwrap(store.configuration.roots.last)
        store.setDefaultMode(.moveToTrash)
        store.setModeOverride(.deletePermanently, forRootID: firstRoot.id)

        let restored = MacArtifactCleanupStore(defaults: defaults)
        let restoredFirstRoot = try XCTUnwrap(restored.configuration.roots.first { $0.id == firstRoot.id })
        let restoredSecondRoot = try XCTUnwrap(restored.configuration.roots.first { $0.id == secondRoot.id })

        XCTAssertEqual(restored.configuration.defaultMode, .moveToTrash)
        XCTAssertEqual(restored.configuration.mode(for: restoredFirstRoot), .deletePermanently)
        XCTAssertEqual(restored.configuration.mode(for: restoredSecondRoot), .moveToTrash)
        let duplicateFolder = await store.addFolder(firstURL)
        XCTAssertFalse(duplicateFolder)
    }

    func testStorePersistsLegacyFuseMigrationOnlyWhenMountedUUIDMatches() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let folderRootID = UUID()
        let externalRootID = UUID()
        let savedConfiguration = MacArtifactCleanupConfiguration(
            defaultMode: .deletePermanently,
            roots: [
                MacArtifactCleanupRoot(
                    id: folderRootID,
                    path: "/Volumes/remote/Photos",
                    kind: .folder,
                    volumeIdentifier: "mount-uuid-1",
                    modeOverride: nil
                ),
                MacArtifactCleanupRoot(
                    id: externalRootID,
                    path: "/Volumes/remote",
                    kind: .externalVolume,
                    volumeIdentifier: "mount-uuid-1",
                    modeOverride: nil
                )
            ]
        )
        defaults.set(
            try JSONEncoder().encode(savedConfiguration),
            forKey: "macArtifactCleanupConfiguration"
        )

        let stableIdentifier = "fuse:source-based"
        let volumeIdentityAt: @Sendable (URL) -> MacArtifactVolumeIdentity? = { url in
            MacArtifactVolumeIdentity(
                identifier: stableIdentifier,
                isFuse: true,
                legacyIdentifier: url.path == "/Volumes/remote" ? "mount-uuid-2" : "mount-uuid-1"
            )
        }

        let store = MacArtifactCleanupStore(
            defaults: defaults,
            volumeIdentityAt: volumeIdentityAt
        )
        let migratedFolder = try XCTUnwrap(store.configuration.roots.first { $0.id == folderRootID })
        let unchangedExternalRoot = try XCTUnwrap(
            store.configuration.roots.first { $0.id == externalRootID }
        )
        XCTAssertEqual(migratedFolder.volumeIdentifier, stableIdentifier)
        XCTAssertEqual(unchangedExternalRoot.volumeIdentifier, "mount-uuid-1")

        let restored = MacArtifactCleanupStore(
            defaults: defaults,
            volumeIdentityAt: { _ in nil }
        )
        XCTAssertEqual(
            restored.configuration.roots.first { $0.id == folderRootID }?.volumeIdentifier,
            stableIdentifier
        )
        XCTAssertEqual(
            restored.configuration.roots.first { $0.id == externalRootID }?.volumeIdentifier,
            "mount-uuid-1"
        )
    }

    func testFolderRootDoesNotSuppressExternalVolumeEnrollment() async throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-tmp/MacArtifactCleanupStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("Selected", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let volumeIdentifier = try XCTUnwrap(
            MacArtifactCleanupRoot.currentVolumeIdentifier(at: folder)
        )
        let store = MacArtifactCleanupStore(defaults: defaults)

        let addedFolder = await store.addFolder(folder)
        XCTAssertTrue(addedFolder)
        XCTAssertTrue(store.enrollExternalVolume(directory, volumeIdentifier: volumeIdentifier))
        XCTAssertEqual(store.configuration.roots.count, 2)
        XCTAssertTrue(store.configuration.roots.contains { $0.kind == .folder })
        XCTAssertTrue(store.configuration.roots.contains { $0.kind == .externalVolume })
    }
    func testContainingRootSelectsMostSpecificSlashBoundedPath() {
        let parent = MacArtifactCleanupRoot(
            id: UUID(),
            path: "/Volumes/Archive",
            kind: .externalVolume,
            volumeIdentifier: "volume-1",
            modeOverride: nil
        )
        let nested = MacArtifactCleanupRoot(
            id: UUID(),
            path: "/Volumes/Archive/Photos",
            kind: .folder,
            volumeIdentifier: "volume-1",
            modeOverride: nil
        )

        XCTAssertEqual(
            MacArtifactCleanupRoot.containing(
                path: "/Volumes/Archive/Photos/image.jpg",
                in: [parent, nested]
            ),
            nested
        )
        XCTAssertEqual(
            MacArtifactCleanupRoot.containing(path: "/Volumes/Archive", in: [parent, nested]),
            parent
        )
        XCTAssertNil(
            MacArtifactCleanupRoot.containing(
                path: "/Volumes/Archive-copy/image.jpg",
                in: [parent]
            )
        )
    }


    func testVolumeEnrollmentRequiresStableIdentifierAndDoesNotDuplicateVolume() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MacArtifactCleanupStore(defaults: defaults)
        let volumeURL = URL(fileURLWithPath: "/Volumes/Archive", isDirectory: true)

        XCTAssertFalse(store.enrollExternalVolume(volumeURL, volumeIdentifier: nil))
        XCTAssertTrue(store.enrollExternalVolume(volumeURL, volumeIdentifier: "volume-123"))
        XCTAssertFalse(store.enrollExternalVolume(volumeURL, volumeIdentifier: "volume-123"))
        XCTAssertEqual(store.configuration.roots.map(\.volumeIdentifier), ["volume-123"])
    }

    func testHistoryIsNewestFirstBoundedAndPersistent() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MacArtifactCleanupStore(defaults: defaults)
        var newestID: UUID?

        for index in 0..<(MacArtifactCleanupStore.historyLimit + 2) {
            let entry = MacArtifactCleanupHistoryEntry(
                rootPath: "/Volumes/Archive/Folder",
                mode: .deletePermanently,
                matchedCount: index,
                removedCount: index,
                skippedCount: 0,
                details: []
            )
            newestID = entry.id
            store.record(entry)
        }

        let restored = MacArtifactCleanupStore(defaults: defaults)

        XCTAssertEqual(restored.history.count, MacArtifactCleanupStore.historyLimit)
        XCTAssertEqual(restored.history.first?.id, newestID)
        XCTAssertEqual(restored.history.first?.matchedCount, MacArtifactCleanupStore.historyLimit + 1)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "MacArtifactCleanupStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
