import Darwin
import Foundation

nonisolated enum MacArtifactSafeTrash {
    struct Source {
        let directory: Int32
        let name: String
        let status: stat
        let validateSource: () throws -> Bool
        let validateMovedEntry: (URL) throws -> Bool
    }

    private struct TrashDirectory {
        let descriptor: Int32
        let url: URL
    }

    static func move(
        _ match: MacArtifactMatch,
        source: Source,
        sourceRoot: Int32,
        beforeMutation: () throws -> Void
    ) throws -> URL? {
        let trash = try openTrashDirectory(for: match, sourceRoot: sourceRoot)
        defer { _ = close(trash.descriptor) }
        guard try source.validateSource() else { return nil }
        try beforeMutation()

        for suffix in 0..<1_000 {
            let name = suffix == 0 ? source.name : "\(source.name) \(suffix)"
            let stagedEntry: MacArtifactSafeFileSystem.StagedEntry
            do {
                guard let result = try MacArtifactSafeFileSystem.stage(
                    sourceDirectory: source.directory,
                    sourceName: source.name,
                    targetStatus: source.status,
                    destinationDirectory: trash.descriptor,
                    destinationName: name
                ) else {
                    return nil
                }
                stagedEntry = result
            } catch let error as POSIXError where error.code == .EEXIST {
                continue
            }

            let destinationURL = trash.url.appendingPathComponent(name)
            let movedEntryIsCurrent: Bool
            do {
                movedEntryIsCurrent = try source.validateMovedEntry(destinationURL)
            } catch {
                let validationError = error
                try MacArtifactSafeFileSystem.rollback(stagedEntry)
                throw validationError
            }
            guard movedEntryIsCurrent,
                  MacArtifactSafeFileSystem.stagedEntryMatches(stagedEntry) else {
                try MacArtifactSafeFileSystem.rollback(stagedEntry)
                return nil
            }
            return destinationURL
        }
        throw POSIXError(.EEXIST)
    }

    private static func openTrashDirectory(
        for match: MacArtifactMatch,
        sourceRoot: Int32
    ) throws -> TrashDirectory {
        if let userTrash = try? FileManager.default.url(
            for: .trashDirectory,
            in: .userDomainMask,
            appropriateFor: match.url,
            create: true
        ).resolvingSymlinksInPath(),
           let descriptor = try? openDirectory(at: userTrash.path) {
            var status = stat()
            if fstat(descriptor, &status) == 0,
               UInt64(status.st_dev) == match.rootDevice,
               status.st_uid == getuid() {
                return TrashDirectory(descriptor: descriptor, url: userTrash)
            }
            _ = close(descriptor)
        }

        let mountPoint = try volumeMountPoint(for: sourceRoot)
        let volumeDescriptor = try openDirectory(at: mountPoint)
        defer { _ = close(volumeDescriptor) }
        var volumeStatus = stat()
        guard fstat(volumeDescriptor, &volumeStatus) == 0,
              UInt64(volumeStatus.st_dev) == match.rootDevice else {
            throw POSIXError(.EXDEV)
        }
        let trashBase = try openOrCreateDirectory(
            at: volumeDescriptor,
            name: ".Trashes",
            mode: mode_t(0o1777),
            device: match.rootDevice
        )
        defer { _ = close(trashBase) }

        let userDirectoryName = String(getuid())
        let userTrash = try openOrCreateDirectory(
            at: trashBase,
            name: userDirectoryName,
            mode: mode_t(0o700),
            device: match.rootDevice
        )
        var userStatus = stat()
        guard fstat(userTrash, &userStatus) == 0,
              userStatus.st_uid == getuid() else {
            _ = close(userTrash)
            throw POSIXError(.EACCES)
        }
        let url = URL(fileURLWithPath: mountPoint, isDirectory: true)
            .appendingPathComponent(".Trashes", isDirectory: true)
            .appendingPathComponent(userDirectoryName, isDirectory: true)
        return TrashDirectory(descriptor: userTrash, url: url)
    }

    private static func openDirectory(at path: String) throws -> Int32 {
        let descriptor = path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        return descriptor
    }

    private static func openOrCreateDirectory(
        at parent: Int32,
        name: String,
        mode: mode_t,
        device: UInt64
    ) throws -> Int32 {
        let created = name.withCString { mkdirat(parent, $0, mode) }
        if created != 0 && errno != EEXIST { throw currentPOSIXError() }
        let descriptor = name.withCString {
            openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              UInt64(status.st_dev) == device else {
            _ = close(descriptor)
            throw POSIXError(.EXDEV)
        }
        return descriptor
    }

    private static func volumeMountPoint(for descriptor: Int32) throws -> String {
        var fileSystem = statfs()
        guard fstatfs(descriptor, &fileSystem) == 0 else { throw currentPOSIXError() }
        let capacity = MemoryLayout.size(ofValue: fileSystem.f_mntonname)
        return withUnsafePointer(to: &fileSystem.f_mntonname) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
