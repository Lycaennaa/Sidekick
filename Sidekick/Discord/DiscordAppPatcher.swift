import AppKit
import Darwin
import Foundation

nonisolated enum DiscordPatchState: Equatable, Sendable {
    case ready
    case installed
    case restoredCleanupRequired
    case backupNameRepairRequired
    case repairRequired
    case anotherModificationDetected
}

nonisolated enum DiscordAppPatcherError: LocalizedError, Sendable {
    case discordRunning
    case anotherModificationDetected
    case repairRequired
    case applicationChanged
    case rollbackFailed(String)
    case restoredButCleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .discordRunning:
            "Quit the selected Discord application completely before installing or restoring Equicord."
        case .anotherModificationDetected:
            "Another Discord client modification or backup was detected. " +
                "Restore the official Discord app before using this installer."
        case .repairRequired:
            "The Sidekick backup, loader, or Equicord payload is missing or inconsistent. Discord was not changed."
        case .applicationChanged:
            "The Discord application changed during the operation. No replacement was made."
        case .rollbackFailed(let details):
            "The operation failed and cleanup was incomplete: \(details)"
        case .restoredButCleanupFailed(let path):
            "Discord was restored, but Sidekick could not remove this leftover file: \(path)"
        }
    }
}

enum DiscordAppPatcher {
    private typealias FileSnapshot = DiscordRestoreCleanup.FileSnapshot

    nonisolated static func state(for target: DiscordInstallTarget) -> DiscordPatchState {
        let hasLoader = EquicordAsarArchive.containsBootstrapMarker(at: target.appArchiveURL)
        let hasBackup = (try? snapshot(target.backupURL)) != nil
        let hasLegacyBackup = (try? snapshot(target.legacyBackupURL)) != nil
        let hasPayload = (try? snapshot(target.payloadURL)) != nil
        let hasForeignBackup = target.foreignBackupURLs.contains(where: itemExists)

        if hasForeignBackup {
            return .anotherModificationDetected
        }
        if hasLoader, hasBackup, hasPayload {
            return .installed
        }
        if hasLoader, hasLegacyBackup, hasPayload, !hasBackup {
            return .backupNameRepairRequired
        }
        if DiscordRestoreCleanup.isPending(for: target, hasLoader: hasLoader) {
            return .restoredCleanupRequired
        }
        if hasLoader || hasBackup || hasLegacyBackup {
            return .repairRequired
        }
        return .ready
    }

    nonisolated static func install(
        target selectedTarget: DiscordInstallTarget,
        artifact: EquicordReleaseArtifact,
        operation: DiscordPatchOperation? = nil
    ) throws {
        try Task.checkCancellation()
        let target = try DiscordInstallTarget.resolve(selectedTarget.applicationURL)
        guard target == selectedTarget else { throw DiscordAppPatcherError.applicationChanged }
        try ensureDiscordIsClosed(target)

        switch state(for: target) {
        case .ready:
            try installFresh(target: target, artifact: artifact, operation: operation)
        case .installed:
            try replaceInstalledPayload(target: target, artifact: artifact, operation: operation)
        case .restoredCleanupRequired, .backupNameRepairRequired, .repairRequired:
            throw DiscordAppPatcherError.repairRequired
        case .anotherModificationDetected:
            throw DiscordAppPatcherError.anotherModificationDetected
        }
    }

    nonisolated static func repairBackupName(
        target selectedTarget: DiscordInstallTarget,
        operation: DiscordPatchOperation? = nil
    ) throws {
        try Task.checkCancellation()
        let target = try DiscordInstallTarget.resolve(selectedTarget.applicationURL)
        guard target == selectedTarget else { throw DiscordAppPatcherError.applicationChanged }
        try ensureDiscordIsClosed(target)
        guard state(for: target) == .backupNameRepairRequired else {
            throw DiscordAppPatcherError.repairRequired
        }

        let loaderSnapshot = try snapshot(target.appArchiveURL)
        let legacyBackupSnapshot = try snapshot(target.legacyBackupURL)
        let backupStage = temporaryURL(in: target.resourcesURL, prefix: "sidekick-backup-repair")
        do {
            try FileManager.default.copyItem(at: target.legacyBackupURL, to: backupStage)
            _ = try EquicordAsarArchive.inspect(fileAt: backupStage)
            try ensureDiscordIsClosed(target)
            guard state(for: target) == .backupNameRepairRequired,
                  snapshotIsCurrent(loaderSnapshot, at: target.appArchiveURL),
                  snapshotIsCurrent(legacyBackupSnapshot, at: target.legacyBackupURL),
                  !itemExists(target.backupURL),
                  EquicordAsarArchive.containsBootstrapMarker(at: target.appArchiveURL) else {
                throw DiscordAppPatcherError.applicationChanged
            }
            try Task.checkCancellation()
            try operation?.admitCommit()
            try atomicRename(from: backupStage, to: target.backupURL)
        } catch {
            let cleanupFailures = removeTemporaryFiles([backupStage])
            if !cleanupFailures.isEmpty {
                throw DiscordAppPatcherError.rollbackFailed(cleanupFailures.joined(separator: ", "))
            }
            throw error
        }

        let cleanupFailures = removeTemporaryFiles([backupStage])
        if !cleanupFailures.isEmpty {
            throw DiscordAppPatcherError.rollbackFailed(cleanupFailures.joined(separator: ", "))
        }
    }

    nonisolated static func uninstall(
        target selectedTarget: DiscordInstallTarget,
        fileManager: FileManager = .default,
        operation: DiscordPatchOperation? = nil
    ) throws {
        try Task.checkCancellation()
        let target = try DiscordInstallTarget.resolve(selectedTarget.applicationURL)
        guard target == selectedTarget else { throw DiscordAppPatcherError.applicationChanged }
        try ensureDiscordIsClosed(target)
        let currentState = state(for: target)
        let restoreURL: URL
        switch currentState {
        case .installed:
            restoreURL = target.backupURL
        case .backupNameRepairRequired:
            restoreURL = target.legacyBackupURL
        case .restoredCleanupRequired:
            try DiscordRestoreCleanup.finish(for: target, fileManager: fileManager)
            return
        case .anotherModificationDetected:
            throw DiscordAppPatcherError.anotherModificationDetected
        case .ready, .repairRequired:
            throw DiscordAppPatcherError.repairRequired
        }

        try restoreOriginalArchive(
            target: target,
            expectedState: currentState,
            backupURL: restoreURL,
            fileManager: fileManager,
            operation: operation
        )
    }

    nonisolated private static func restoreOriginalArchive(
        target: DiscordInstallTarget,
        expectedState: DiscordPatchState,
        backupURL: URL,
        fileManager: FileManager,
        operation: DiscordPatchOperation?
    ) throws {
        let loaderSnapshot = try snapshot(target.appArchiveURL)
        let backupSnapshot = try snapshot(backupURL)
        let cleanupFiles = try DiscordRestoreCleanup.fileSnapshots(for: target)
        let restoreStage = temporaryURL(in: target.resourcesURL, prefix: "sidekick-restore")
        var markerWritten = false
        do {
            try fileManager.copyItem(at: backupURL, to: restoreStage)
            _ = try EquicordAsarArchive.inspect(fileAt: restoreStage)
            try ensureDiscordIsClosed(target)
            try Task.checkCancellation()
            guard state(for: target) == expectedState,
                  snapshotIsCurrent(loaderSnapshot, at: target.appArchiveURL),
                  snapshotIsCurrent(backupSnapshot, at: backupURL),
                  DiscordRestoreCleanup.filesAreCurrent(cleanupFiles, for: target),
                  EquicordAsarArchive.containsBootstrapMarker(at: target.appArchiveURL) else {
                throw DiscordAppPatcherError.applicationChanged
            }
            let marker = try DiscordRestoreCleanup.makeMarker(
                target: target,
                restoreURL: backupURL,
                stagedArchiveURL: restoreStage,
                cleanupFiles: cleanupFiles
            )
            try DiscordRestoreCleanup.writeMarker(marker, for: target)
            markerWritten = true
            try Task.checkCancellation()
            guard state(for: target) == expectedState,
                  snapshotIsCurrent(loaderSnapshot, at: target.appArchiveURL),
                  snapshotIsCurrent(backupSnapshot, at: backupURL),
                  marker.restoredArchive.isCurrent(at: restoreStage),
                  DiscordRestoreCleanup.filesAreCurrent(marker.cleanupFiles, for: target) else {
                throw DiscordAppPatcherError.applicationChanged
            }
            try operation?.admitCommit()
            try atomicRename(from: restoreStage, to: target.appArchiveURL)
        } catch {
            var cleanupFailures = removeTemporaryFiles([restoreStage])
            if markerWritten {
                cleanupFailures.append(contentsOf: DiscordRestoreCleanup.removeMarker(
                    for: target,
                    fileManager: fileManager
                ))
            }
            if !cleanupFailures.isEmpty {
                throw DiscordAppPatcherError.rollbackFailed(cleanupFailures.joined(separator: ", "))
            }
            throw error
        }

        try DiscordRestoreCleanup.finish(for: target, fileManager: fileManager)
    }

    nonisolated private static func installFresh(
        target: DiscordInstallTarget,
        artifact: EquicordReleaseArtifact,
        operation: DiscordPatchOperation?
    ) throws {
        guard target.foreignBackupURLs.allSatisfy({ !itemExists($0) }),
              !itemExists(target.backupURL) else {
            throw DiscordAppPatcherError.anotherModificationDetected
        }

        let originalSnapshot = try snapshot(target.appArchiveURL)
        _ = try EquicordAsarArchive.inspect(fileAt: target.appArchiveURL)
        let payloadStage = temporaryURL(in: target.resourcesURL, prefix: "sidekick-equicord")
        let loaderStage = temporaryURL(in: target.resourcesURL, prefix: "sidekick-bootstrap")
        let backupStage = temporaryURL(in: target.resourcesURL, prefix: "sidekick-backup")
        var backupCreated = false
        var payloadInstalled = false
        var loaderInstalled = false

        do {
            switch artifact.lifetime {
            case .temporary:
                try FileManager.default.moveItem(at: artifact.fileURL, to: payloadStage)
            case .retainedSource:
                try FileManager.default.copyItem(at: artifact.fileURL, to: payloadStage)
            }
            try EquicordAsarArchive.makeBootstrap(payloadURL: target.payloadURL).write(to: loaderStage)
            try FileManager.default.copyItem(at: target.appArchiveURL, to: backupStage)
            _ = try EquicordAsarArchive.inspect(fileAt: backupStage)
            guard snapshotIsCurrent(originalSnapshot, at: target.appArchiveURL) else {
                throw DiscordAppPatcherError.applicationChanged
            }
            try Task.checkCancellation()
            try atomicRename(from: backupStage, to: target.backupURL)
            backupCreated = true

            try ensureDiscordIsClosed(target)
            guard snapshotIsCurrent(originalSnapshot, at: target.appArchiveURL),
                  !EquicordAsarArchive.containsBootstrapMarker(at: target.appArchiveURL) else {
                throw DiscordAppPatcherError.applicationChanged
            }
            try Task.checkCancellation()
            try atomicRename(from: payloadStage, to: target.payloadURL)
            payloadInstalled = true
            try Task.checkCancellation()
            try operation?.admitCommit()
            try atomicRename(from: loaderStage, to: target.appArchiveURL)
            loaderInstalled = true
        } catch {
            var cleanupFailures = rollbackFreshInstall(
                target: target,
                originalSnapshot: originalSnapshot,
                backupCreated: backupCreated,
                payloadInstalled: payloadInstalled,
                loaderInstalled: loaderInstalled
            )
            cleanupFailures.append(contentsOf: removeTemporaryFiles([payloadStage, loaderStage, backupStage]))
            guard cleanupFailures.isEmpty else {
                throw DiscordAppPatcherError.rollbackFailed(cleanupFailures.joined(separator: ", "))
            }
            throw error
        }

        let cleanupFailures = removeTemporaryFiles([payloadStage, loaderStage, backupStage])
        guard cleanupFailures.isEmpty else {
            throw DiscordAppPatcherError.rollbackFailed(cleanupFailures.joined(separator: ", "))
        }
    }

    nonisolated private static func rollbackFreshInstall(
        target: DiscordInstallTarget,
        originalSnapshot: FileSnapshot,
        backupCreated: Bool,
        payloadInstalled: Bool,
        loaderInstalled: Bool
    ) -> [String] {
        var failures: [String] = []
        if !loaderInstalled, snapshotIsCurrent(originalSnapshot, at: target.appArchiveURL) {
            if payloadInstalled {
                do { try FileManager.default.removeItem(at: target.payloadURL) } catch {
                    failures.append(target.payloadURL.path)
                }
            }
            if backupCreated {
                do { try FileManager.default.removeItem(at: target.backupURL) } catch {
                    failures.append(target.backupURL.path)
                }
            }
        }
        return failures
    }

    nonisolated private static func replaceInstalledPayload(
        target: DiscordInstallTarget,
        artifact: EquicordReleaseArtifact,
        operation: DiscordPatchOperation?
    ) throws {
        try Task.checkCancellation()
        guard state(for: target) == .installed else { throw DiscordAppPatcherError.repairRequired }
        let loaderSnapshot = try snapshot(target.appArchiveURL)
        let backupSnapshot = try snapshot(target.backupURL)
        let payloadStage = temporaryURL(in: target.resourcesURL, prefix: "sidekick-equicord")

        do {
            switch artifact.lifetime {
            case .temporary:
                try FileManager.default.moveItem(at: artifact.fileURL, to: payloadStage)
            case .retainedSource:
                try FileManager.default.copyItem(at: artifact.fileURL, to: payloadStage)
            }
            try ensureDiscordIsClosed(target)
            guard state(for: target) == .installed,
                  snapshotIsCurrent(loaderSnapshot, at: target.appArchiveURL),
                  snapshotIsCurrent(backupSnapshot, at: target.backupURL) else {
                throw DiscordAppPatcherError.applicationChanged
            }
            try Task.checkCancellation()
            try operation?.admitCommit()
            try atomicRename(from: payloadStage, to: target.payloadURL)
        } catch {
            let cleanupFailures = removeTemporaryFiles([payloadStage])
            if !cleanupFailures.isEmpty {
                throw DiscordAppPatcherError.rollbackFailed(cleanupFailures.joined(separator: ", "))
            }
            throw error
        }

        let cleanupFailures = removeTemporaryFiles([payloadStage])
        if !cleanupFailures.isEmpty {
            throw DiscordAppPatcherError.rollbackFailed(cleanupFailures.joined(separator: ", "))
        }
    }

    nonisolated private static func ensureDiscordIsClosed(_ target: DiscordInstallTarget) throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleIdentifier).isEmpty else {
            throw DiscordAppPatcherError.discordRunning
        }
    }

    nonisolated private static func snapshot(_ url: URL) throws -> FileSnapshot {
        try FileSnapshot.read(url)
    }

    nonisolated private static func snapshotIsCurrent(_ expected: FileSnapshot, at url: URL) -> Bool {
        expected.isCurrent(at: url)
    }

    nonisolated private static func itemExists(_ url: URL) -> Bool {
        FileSnapshot.itemExists(url)
    }

    nonisolated private static func temporaryURL(in directory: URL, prefix: String) -> URL {
        directory.appendingPathComponent(".\(prefix)-\(UUID().uuidString).tmp")
    }

    nonisolated private static func atomicRename(from source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    nonisolated private static func removeTemporaryFiles(_ urls: [URL]) -> [String] {
        urls.compactMap { url in
            guard itemExists(url) else { return nil }
            do {
                try FileManager.default.removeItem(at: url)
                return nil
            } catch {
                return url.path
            }
        }
    }
}
