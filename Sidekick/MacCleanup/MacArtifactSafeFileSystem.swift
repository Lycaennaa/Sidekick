import Darwin
import Foundation

nonisolated enum MacArtifactSafeFileSystem {
    private struct OpenedLocation {
        let descriptors: [Int32]
        let parentComponents: [String]
        let parent: Int32
        let leaf: String
        let targetDescriptor: Int32
        let targetStatus: stat
    }

    struct StagedEntry {
        let sourceDirectory: Int32
        let sourceName: String
        let destinationDirectory: Int32
        let destinationName: String
        let targetStatus: stat
        let movedStatus: stat
        let isDirectory: Bool
    }

    static func remove(
        _ match: MacArtifactMatch,
        beforeStagedEntryValidation: () throws -> Void = {},
        beforeMutation: () throws -> Void = {}
    ) throws -> Bool {
        let location = try MacArtifactSafeLocation.openLocation(for: match)
        defer { location.descriptors.reversed().forEach { _ = close($0) } }
        guard try MacArtifactSafeLocation.isCurrent(
            location,
            for: match,
            sourceEntryMustMatch: true
        ) else {
            return false
        }

        try beforeMutation()
        guard let stagedEntry = try stageForPermanentRemoval(location) else { return false }
        return try removeStagedEntry(
            stagedEntry,
            from: location,
            match: match,
            beforeValidation: beforeStagedEntryValidation
        )
    }
    private static func stageForPermanentRemoval(
        _ location: MacArtifactSafeLocation.OpenedLocation
    ) throws -> StagedEntry? {
        for _ in 0..<32 {
            let stageName = ".sidekick-cleanup-\(UUID().uuidString)"
            do {
                return try stage(
                    sourceDirectory: location.parent,
                    sourceName: location.leaf,
                    targetStatus: location.targetStatus,
                    destinationDirectory: location.parent,
                    destinationName: stageName
                )
            } catch let error as POSIXError where error.code == .EEXIST {
                continue
            }
        }
        return nil
    }
    private static func removeStagedEntry(
        _ stagedEntry: StagedEntry,
        from location: MacArtifactSafeLocation.OpenedLocation,
        match: MacArtifactMatch,
        beforeValidation: () throws -> Void
    ) throws -> Bool {
        let isCurrentAfterStage: Bool
        do {
            try beforeValidation()
            isCurrentAfterStage = try MacArtifactSafeLocation.isCurrent(
                location,
                for: match,
                sourceEntryMustMatch: false,
                postMove: true
            )
        } catch {
            let validationError = error
            try rollback(stagedEntry)
            throw validationError
        }
        guard isCurrentAfterStage, stagedEntryMatches(stagedEntry) else {
            try rollback(stagedEntry)
            return false
        }

        if match.kind == .metadataDirectory {
            do {
                try MacArtifactSafeDirectoryTraversal.removeContents(
                    at: location.targetDescriptor,
                    path: match.url.path,
                    device: match.rootDevice
                )
            } catch {
                let removalError = error
                try rollback(stagedEntry)
                throw removalError
            }
        }
        guard stagedEntryMatches(stagedEntry) else {
            try rollback(stagedEntry)
            return false
        }

        let removed = stagedEntry.destinationName.withCString {
            unlinkat(
                stagedEntry.destinationDirectory,
                $0,
                stagedEntry.isDirectory ? AT_REMOVEDIR : 0
            )
        }
        guard removed == 0 else {
            let removalError = currentPOSIXError()
            try rollback(stagedEntry)
            throw removalError
        }
        return true
    }
    static func moveToTrash(
        _ match: MacArtifactMatch,
        beforeMovedEntryValidation: @escaping (URL) throws -> Void = { _ in },
        beforeMutation: () throws -> Void = {}
    ) throws -> URL? {
        let location = try MacArtifactSafeLocation.openLocation(for: match)
        defer { location.descriptors.reversed().forEach { _ = close($0) } }
        guard try MacArtifactSafeLocation.isCurrent(location, for: match, sourceEntryMustMatch: true) else { return nil }
        return try MacArtifactSafeTrash.move(
            match,
            source: MacArtifactSafeTrash.Source(
                directory: location.parent,
                name: location.leaf,
                status: location.targetStatus,
                validateSource: {
                    try MacArtifactSafeLocation.isCurrent(location, for: match, sourceEntryMustMatch: true)
                },
                validateMovedEntry: { destinationURL in
                    try beforeMovedEntryValidation(destinationURL)
                    return try MacArtifactSafeLocation.isCurrent(location, for: match, sourceEntryMustMatch: false, postMove: true)
                }
            ),
            sourceRoot: location.descriptors[0],
            beforeMutation: beforeMutation
        )
    }

    static func stage(
        sourceDirectory: Int32,
        sourceName: String,
        targetStatus: stat,
        destinationDirectory: Int32,
        destinationName: String
    ) throws -> StagedEntry? {
        let result = sourceName.withCString { oldName in
            destinationName.withCString { newName in
                renameatx_np(sourceDirectory, oldName, destinationDirectory, newName, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw currentPOSIXError() }
        var movedStatus = stat()
        guard destinationName.withCString({
            fstatat(destinationDirectory, $0, &movedStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0 else {
            throw currentPOSIXError()
        }

        let stagedEntry = StagedEntry(
            sourceDirectory: sourceDirectory,
            sourceName: sourceName,
            destinationDirectory: destinationDirectory,
            destinationName: destinationName,
            targetStatus: targetStatus,
            movedStatus: movedStatus,
            isDirectory: targetStatus.st_mode & S_IFMT == S_IFDIR
        )
        guard MacArtifactSafeLocation.entryMatches(targetStatus, name: destinationName, in: destinationDirectory) else {
            try rollback(stagedEntry)
            return nil
        }
        return stagedEntry
    }

    static func stagedEntryMatches(_ stagedEntry: StagedEntry) -> Bool {
        MacArtifactSafeLocation.entryMatches(
            stagedEntry.targetStatus,
            name: stagedEntry.destinationName,
            in: stagedEntry.destinationDirectory
        )
    }

    static func rollback(_ stagedEntry: StagedEntry) throws {
        guard MacArtifactSafeLocation.entryMatches(
            stagedEntry.movedStatus,
            name: stagedEntry.destinationName,
            in: stagedEntry.destinationDirectory
        ) else {
            throw POSIXError(.ESTALE)
        }
        let result = stagedEntry.destinationName.withCString { movedName in
            stagedEntry.sourceName.withCString { sourceName in
                renameatx_np(
                    stagedEntry.destinationDirectory,
                    movedName,
                    stagedEntry.sourceDirectory,
                    sourceName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else { throw currentPOSIXError() }
    }
    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
