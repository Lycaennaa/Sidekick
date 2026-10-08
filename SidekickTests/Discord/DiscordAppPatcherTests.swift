import Foundation
import XCTest

private final class FailingRemovalFileManager: FileManager {
    private let failureURL: URL

    init(failureURL: URL) {
        self.failureURL = failureURL.standardizedFileURL
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        guard URL.standardizedFileURL == failureURL else {
            try super.removeItem(at: URL)
            return
        }
        throw CocoaError(.fileWriteNoPermission)
    }
}

@MainActor
final class DiscordAppPatcherTests: XCTestCase {
    func testDefaultPatcherInstallsAndRestoresUsingRealFilesystem() throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let originalArchive = try EquicordAsarArchive.makeArchive(files: [
            "index.js": Data("module.exports = 'stock';".utf8),
            "package.json": Data("{\"name\":\"discord\"}".utf8)
        ])
        let target = try DiscordTestFixture.makeApplication(at: root, originalArchive: originalArchive)
        let artifact = try DiscordTestFixture.makeArtifact(in: root)
        let artifactBytes = try Data(contentsOf: artifact.fileURL)

        try DiscordAppPatcher.install(target: target, artifact: artifact)

        XCTAssertEqual(DiscordAppPatcher.state(for: target), .installed)
        XCTAssertTrue(EquicordAsarArchive.containsBootstrapMarker(at: target.appArchiveURL))
        XCTAssertEqual(target.backupURL.lastPathComponent, "_app.asar")
        XCTAssertEqual(try Data(contentsOf: target.backupURL), originalArchive)
        XCTAssertEqual(try EquicordAsarArchive.inspect(fileAt: target.backupURL).fileCount, 2)
        XCTAssertEqual(try Data(contentsOf: target.payloadURL), artifactBytes)

        try DiscordAppPatcher.uninstall(target: target)

        XCTAssertEqual(try Data(contentsOf: target.appArchiveURL), originalArchive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.payloadURL.path))
        XCTAssertEqual(DiscordAppPatcher.state(for: target), .ready)
    }

    func testMigratesLegacyBackupToEquicordPathAndRestores() throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let originalArchive = try EquicordAsarArchive.makeArchive(files: [
            "index.js": Data("module.exports = 'stock';".utf8),
            "package.json": Data("{\"name\":\"discord\"}".utf8)
        ])
        let target = try DiscordTestFixture.makeApplication(at: root, originalArchive: originalArchive)
        let artifact = try DiscordTestFixture.makeArtifact(in: root)
        try FileManager.default.copyItem(at: target.appArchiveURL, to: target.legacyBackupURL)
        try FileManager.default.copyItem(at: artifact.fileURL, to: target.payloadURL)
        try EquicordAsarArchive.makeBootstrap(payloadURL: target.payloadURL).write(to: target.appArchiveURL)

        XCTAssertEqual(DiscordAppPatcher.state(for: target), .backupNameRepairRequired)
        try DiscordAppPatcher.repairBackupName(target: target)

        XCTAssertEqual(DiscordAppPatcher.state(for: target), .installed)
        XCTAssertEqual(try Data(contentsOf: target.backupURL), originalArchive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.legacyBackupURL.path))
        try DiscordAppPatcher.uninstall(target: target)

        XCTAssertEqual(try Data(contentsOf: target.appArchiveURL), originalArchive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.legacyBackupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.payloadURL.path))
    }
    func testRestoreRefusesToOverwriteArchiveChangedAfterInstall() throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let originalArchive = try EquicordAsarArchive.makeArchive(files: [
            "index.js": Data("module.exports = 'stock';".utf8)
        ])
        let target = try DiscordTestFixture.makeApplication(at: root, originalArchive: originalArchive)
        let artifact = try DiscordTestFixture.makeArtifact(in: root)
        try DiscordAppPatcher.install(target: target, artifact: artifact)

        let updatedArchive = try EquicordAsarArchive.makeArchive(files: [
            "index.js": Data("module.exports = 'discord update';".utf8)
        ])
        try updatedArchive.write(to: target.appArchiveURL)

        XCTAssertThrowsError(try DiscordAppPatcher.uninstall(target: target))
        XCTAssertEqual(try Data(contentsOf: target.appArchiveURL), updatedArchive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.backupURL.path))
    }
    func testRestoreCleanupFailureCanBeRetried() throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let originalArchive = try EquicordAsarArchive.makeArchive(files: [
            "index.js": Data("module.exports = 'stock';".utf8)
        ])
        let target = try DiscordTestFixture.makeApplication(at: root, originalArchive: originalArchive)
        let artifact = try DiscordTestFixture.makeArtifact(in: root)
        try DiscordAppPatcher.install(target: target, artifact: artifact)

        let fileManager = FailingRemovalFileManager(failureURL: target.payloadURL)
        XCTAssertThrowsError(try DiscordAppPatcher.uninstall(target: target, fileManager: fileManager))

        XCTAssertEqual(try Data(contentsOf: target.appArchiveURL), originalArchive)
        XCTAssertEqual(DiscordAppPatcher.state(for: target), .restoredCleanupRequired)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.backupURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.payloadURL.path))

        try DiscordAppPatcher.uninstall(target: target)

        XCTAssertEqual(DiscordAppPatcher.state(for: target), .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.payloadURL.path))
    }
}
