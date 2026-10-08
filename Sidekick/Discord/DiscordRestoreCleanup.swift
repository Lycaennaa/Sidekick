import Darwin
import Foundation

enum DiscordRestoreCleanup {
    nonisolated struct FileSnapshot: Codable, Equatable, Sendable {
        let size: Int64
        let device: UInt64
        let inode: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64

        nonisolated static func read(_ url: URL) throws -> FileSnapshot {
            var fileInfo = stat()
            guard lstat(url.path, &fileInfo) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard (fileInfo.st_mode & S_IFMT) == S_IFREG else {
                throw DiscordAppPatcherError.applicationChanged
            }
            return FileSnapshot(
                size: Int64(fileInfo.st_size),
                device: UInt64(fileInfo.st_dev),
                inode: UInt64(fileInfo.st_ino),
                modifiedSeconds: Int64(fileInfo.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(fileInfo.st_mtimespec.tv_nsec)
            )
        }

        nonisolated func isCurrent(at url: URL) -> Bool {
            (try? Self.read(url)) == self
        }

        nonisolated static func itemExists(_ url: URL) -> Bool {
            var fileInfo = stat()
            return lstat(url.path, &fileInfo) == 0
        }
    }

    nonisolated enum Backup: String, Codable, Sendable {
        case primary
        case legacy

        var fileName: String {
            switch self {
            case .primary: "_app.asar"
            case .legacy: "app.asar.sidekick-original"
            }
        }
    }

    nonisolated struct Marker: Codable, Equatable, Sendable {
        let restoredArchive: FileSnapshot
        let restoreBackup: Backup
        let cleanupFiles: [String: FileSnapshot]
    }

    nonisolated static func isPending(for target: DiscordInstallTarget, hasLoader: Bool) -> Bool {
        guard !hasLoader,
              let marker = loadMarker(for: target),
              marker.restoredArchive.isCurrent(at: target.appArchiveURL) else {
            return false
        }
        return true
    }

    nonisolated static func fileSnapshots(for target: DiscordInstallTarget) throws -> [String: FileSnapshot] {
        var snapshots: [String: FileSnapshot] = [:]
        for url in sidecarURLs(for: target) where FileSnapshot.itemExists(url) {
            snapshots[url.lastPathComponent] = try FileSnapshot.read(url)
        }
        return snapshots
    }

    nonisolated static func makeMarker(
        target: DiscordInstallTarget,
        restoreURL: URL,
        stagedArchiveURL: URL,
        cleanupFiles: [String: FileSnapshot]
    ) throws -> Marker {
        let backup: Backup = restoreURL == target.backupURL ? .primary : .legacy
        guard cleanupFiles[backup.fileName] != nil else {
            throw DiscordAppPatcherError.applicationChanged
        }
        return Marker(
            restoredArchive: try FileSnapshot.read(stagedArchiveURL),
            restoreBackup: backup,
            cleanupFiles: cleanupFiles
        )
    }

    nonisolated static func writeMarker(_ marker: Marker, for target: DiscordInstallTarget) throws {
        let data = try PropertyListEncoder().encode(marker)
        try data.write(to: target.restoreMarkerURL, options: .atomic)
    }

    nonisolated static func filesAreCurrent(
        _ expectedFiles: [String: FileSnapshot],
        for target: DiscordInstallTarget
    ) -> Bool {
        sidecarURLs(for: target).allSatisfy { url in
            guard let expected = expectedFiles[url.lastPathComponent] else {
                return !FileSnapshot.itemExists(url)
            }
            return expected.isCurrent(at: url)
        }
    }

    nonisolated static func removeMarker(for target: DiscordInstallTarget, fileManager: FileManager) -> [String] {
        guard FileSnapshot.itemExists(target.restoreMarkerURL) else { return [] }
        do {
            try fileManager.removeItem(at: target.restoreMarkerURL)
            return []
        } catch {
            return [target.restoreMarkerURL.path]
        }
    }

    nonisolated static func finish(for target: DiscordInstallTarget, fileManager: FileManager) throws {
        guard let marker = loadMarker(for: target) else {
            throw DiscordAppPatcherError.applicationChanged
        }
        try ensureCurrent(marker, for: target)
        let restoreURL = backupURL(marker.restoreBackup, for: target)
        if FileSnapshot.itemExists(restoreURL) {
            guard let expected = marker.cleanupFiles[restoreURL.lastPathComponent],
                  expected.isCurrent(at: restoreURL),
                  FileManager.default.contentsEqual(atPath: target.appArchiveURL.path, andPath: restoreURL.path) else {
                throw DiscordAppPatcherError.applicationChanged
            }
        }

        for url in sidecarURLs(for: target) where url != restoreURL {
            try remove(url, marker: marker, target: target, fileManager: fileManager)
        }
        try remove(restoreURL, marker: marker, target: target, fileManager: fileManager)
        try ensureCurrent(marker, for: target)
        guard sidecarURLs(for: target).allSatisfy({ !FileSnapshot.itemExists($0) }) else {
            throw DiscordAppPatcherError.applicationChanged
        }
        try Task.checkCancellation()
        do {
            try fileManager.removeItem(at: target.restoreMarkerURL)
        } catch {
            throw DiscordAppPatcherError.restoredButCleanupFailed(target.restoreMarkerURL.path)
        }
    }

    private nonisolated static func ensureCurrent(_ marker: Marker, for target: DiscordInstallTarget) throws {
        guard target.foreignBackupURLs.allSatisfy({ !FileSnapshot.itemExists($0) }) else {
            throw DiscordAppPatcherError.anotherModificationDetected
        }
        guard loadMarker(for: target) == marker,
              marker.restoredArchive.isCurrent(at: target.appArchiveURL),
              !EquicordAsarArchive.containsBootstrapMarker(at: target.appArchiveURL) else {
            throw DiscordAppPatcherError.applicationChanged
        }
    }

    private nonisolated static func remove(
        _ url: URL,
        marker: Marker,
        target: DiscordInstallTarget,
        fileManager: FileManager
    ) throws {
        guard FileSnapshot.itemExists(url) else { return }
        guard let expected = marker.cleanupFiles[url.lastPathComponent], expected.isCurrent(at: url) else {
            throw DiscordAppPatcherError.applicationChanged
        }
        try ensureCurrent(marker, for: target)
        try Task.checkCancellation()
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw DiscordAppPatcherError.restoredButCleanupFailed(url.path)
        }
    }

    private nonisolated static func loadMarker(for target: DiscordInstallTarget) -> Marker? {
        guard let file = try? FileSnapshot.read(target.restoreMarkerURL),
              file.size <= 4 * 1024,
              let data = try? Data(contentsOf: target.restoreMarkerURL),
              let marker = try? PropertyListDecoder().decode(Marker.self, from: data),
              marker.cleanupFiles[marker.restoreBackup.fileName] != nil else {
            return nil
        }
        return marker
    }

    private nonisolated static func sidecarURLs(for target: DiscordInstallTarget) -> [URL] {
        [target.payloadURL, target.backupURL, target.legacyBackupURL]
    }

    private nonisolated static func backupURL(_ backup: Backup, for target: DiscordInstallTarget) -> URL {
        switch backup {
        case .primary: target.backupURL
        case .legacy: target.legacyBackupURL
        }
    }
}
