import XCTest

@MainActor
final class MacArtifactCleanupStoreTests: XCTestCase {
    func testRootModesPersistWithGlobalDefaultAndPerRootOverride() throws {
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

        XCTAssertTrue(store.addFolder(firstURL))
        XCTAssertTrue(store.addFolder(secondURL))
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
        XCTAssertFalse(store.addFolder(firstURL))
    }

    func testFolderRootDoesNotSuppressExternalVolumeEnrollment() throws {
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

        XCTAssertTrue(store.addFolder(folder))
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
