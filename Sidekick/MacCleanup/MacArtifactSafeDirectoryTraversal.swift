import Darwin
import Foundation

nonisolated enum MacArtifactSafeDirectoryTraversal {
    static func fingerprintDirectory(
        at descriptor: Int32,
        path: String,
        device: UInt64,
        entries: inout [MacArtifactFingerprint.Entry]
    ) throws {
        var directoryStatus = stat()
        guard fstat(descriptor, &directoryStatus) == 0,
              directoryStatus.st_mode & S_IFMT == S_IFDIR,
              UInt64(directoryStatus.st_dev) == device else {
            throw currentPOSIXError()
        }
        entries.append(MacArtifactScanner.entry(for: directoryStatus, path: path))

        for name in try directoryNames(at: descriptor) {
            var status = stat()
            guard name.withCString({ fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW) }) == 0,
                  UInt64(status.st_dev) == device else {
                throw currentPOSIXError()
            }
            let childPath = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(name).path
            entries.append(MacArtifactScanner.entry(for: status, path: childPath))
            guard status.st_mode & S_IFMT == S_IFDIR else { continue }
            guard !MacArtifactScanner.isPackage(URL(fileURLWithPath: childPath, isDirectory: true)) else {
                throw POSIXError(.EPERM)
            }
            let childDescriptor = name.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard childDescriptor >= 0 else { throw currentPOSIXError() }
            defer { _ = close(childDescriptor) }
            var openedStatus = stat()
            guard fstat(childDescriptor, &openedStatus) == 0,
                  openedStatus.st_dev == status.st_dev,
                  openedStatus.st_ino == status.st_ino else {
                throw POSIXError(.ESTALE)
            }
            try fingerprintDirectory(
                at: childDescriptor,
                path: childPath,
                device: device,
                entries: &entries
            )
        }
    }

    static func removeContents(at descriptor: Int32, path: String, device: UInt64) throws {
        for name in try directoryNames(at: descriptor) {
            var status = stat()
            guard name.withCString({ fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW) }) == 0,
                  UInt64(status.st_dev) == device else {
                throw currentPOSIXError()
            }
            if status.st_mode & S_IFMT == S_IFDIR {
                let childPath = URL(fileURLWithPath: path, isDirectory: true)
                    .appendingPathComponent(name).path
                guard !MacArtifactScanner.isPackage(URL(fileURLWithPath: childPath, isDirectory: true)) else {
                    throw POSIXError(.EPERM)
                }
                let childDescriptor = name.withCString {
                    openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard childDescriptor >= 0 else { throw currentPOSIXError() }
                defer { _ = close(childDescriptor) }
                var openedStatus = stat()
                guard fstat(childDescriptor, &openedStatus) == 0,
                      openedStatus.st_dev == status.st_dev,
                      openedStatus.st_ino == status.st_ino else {
                    throw POSIXError(.ESTALE)
                }
                try removeContents(at: childDescriptor, path: childPath, device: device)
                var currentStatus = stat()
                guard name.withCString({
                    fstatat(descriptor, $0, &currentStatus, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                      currentStatus.st_dev == openedStatus.st_dev,
                      currentStatus.st_ino == openedStatus.st_ino,
                      currentStatus.st_mode & S_IFMT == S_IFDIR else {
                    throw POSIXError(.ESTALE)
                }
                guard name.withCString({ unlinkat(descriptor, $0, AT_REMOVEDIR) }) == 0 else {
                    throw currentPOSIXError()
                }
            } else {
                guard name.withCString({ unlinkat(descriptor, $0, 0) }) == 0 else {
                    throw currentPOSIXError()
                }
            }
        }
    }

    private static func directoryNames(at descriptor: Int32) throws -> [String] {
        let duplicate = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard duplicate >= 0 else { throw currentPOSIXError() }
        guard let directory = fdopendir(duplicate) else {
            let error = currentPOSIXError()
            _ = close(duplicate)
            throw error
        }
        defer { _ = closedir(directory) }

        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { throw currentPOSIXError() }
                return names
            }
            let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        guard errno == 0 else { throw currentPOSIXError() }
        return names
    }
    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
