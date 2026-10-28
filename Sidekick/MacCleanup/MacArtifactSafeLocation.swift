import Darwin
import Foundation

nonisolated enum MacArtifactSafeLocation {
    struct OpenedLocation {
        let descriptors: [Int32]
        let parentComponents: [String]
        let parent: Int32
        let leaf: String
        let targetDescriptor: Int32
        let targetStatus: stat
    }

    static func entryMatches(_ expected: stat, name: String, in directory: Int32) -> Bool {
        var status = stat()
        guard name.withCString({ fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            return false
        }
        return status.st_dev == expected.st_dev
            && status.st_ino == expected.st_ino
            && status.st_mode & S_IFMT == expected.st_mode & S_IFMT
    }

    static func isCurrent(
        _ location: OpenedLocation,
        for match: MacArtifactMatch,
        sourceEntryMustMatch: Bool,
        postMove: Bool = false
    ) throws -> Bool {
        guard parentChainIsCurrent(location, for: match) else { return false }
        guard let fingerprint = try fingerprint(
            at: location,
            for: match,
            sourceEntryMustMatch: sourceEntryMustMatch
        ) else { return false }
        guard postMove else { return fingerprint == match.fingerprint }
        return fingerprintMatchesAfterMove(
            fingerprint,
            expected: match.fingerprint,
            targetPath: match.url.path
        )
    }
    private static func fingerprintMatchesAfterMove(
        _ actual: MacArtifactFingerprint,
        expected: MacArtifactFingerprint,
        targetPath: String
    ) -> Bool {
        guard actual.entries.count == expected.entries.count else { return false }
        for (actualEntry, expectedEntry) in zip(actual.entries, expected.entries) {
            guard actualEntry.path == expectedEntry.path,
                  actualEntry.device == expectedEntry.device,
                  actualEntry.inode == expectedEntry.inode,
                  actualEntry.mode == expectedEntry.mode,
                  actualEntry.size == expectedEntry.size,
                  actualEntry.modificationSeconds == expectedEntry.modificationSeconds,
                  actualEntry.modificationNanoseconds == expectedEntry.modificationNanoseconds,
                  actualEntry.path == targetPath
                    || (
                        actualEntry.changeSeconds == expectedEntry.changeSeconds
                            && actualEntry.changeNanoseconds == expectedEntry.changeNanoseconds
                    ) else {
                return false
            }
        }
        return true
    }
    private static func parentChainIsCurrent(
        _ location: OpenedLocation,
        for match: MacArtifactMatch
    ) -> Bool {
        let rootPath = match.rootURL.standardizedFileURL.path
        let currentRootDescriptor = rootPath.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard currentRootDescriptor >= 0 else { return false }
        defer { _ = close(currentRootDescriptor) }

        var currentRootStatus = stat()
        var openedRootStatus = stat()
        guard fstat(currentRootDescriptor, &currentRootStatus) == 0,
              fstat(location.descriptors[0], &openedRootStatus) == 0,
              currentRootStatus.st_dev == openedRootStatus.st_dev,
              currentRootStatus.st_ino == openedRootStatus.st_ino,
              currentRootStatus.st_mode & S_IFMT == openedRootStatus.st_mode & S_IFMT else {
            return false
        }

        var parent = location.descriptors[0]
        for (index, component) in location.parentComponents.enumerated() {
            var childStatus = stat()
            guard fstat(location.descriptors[index + 1], &childStatus) == 0,
                  childStatus.st_mode & S_IFMT == S_IFDIR,
                  entryMatches(childStatus, name: component, in: parent) else {
                return false
            }
            parent = location.descriptors[index + 1]
        }
        return true
    }

    static func openLocation(for match: MacArtifactMatch) throws -> OpenedLocation {
        let (rootPath, components) = try relativeComponents(for: match)
        var descriptors: [Int32] = []
        var keepDescriptors = false
        defer {
            if !keepDescriptors {
                descriptors.reversed().forEach { _ = close($0) }
            }
        }

        let rootDescriptor = try openRootDescriptor(at: rootPath, device: match.rootDevice)
        descriptors.append(rootDescriptor)
        let parent = try openParentDirectories(
            Array(components.dropLast()),
            rootDescriptor: rootDescriptor,
            device: match.rootDevice,
            descriptors: &descriptors
        )
        let leaf = components[components.count - 1]
        let target = try openTarget(
            leaf,
            in: parent,
            match: match,
            descriptors: &descriptors
        )

        keepDescriptors = true
        return OpenedLocation(
            descriptors: descriptors,
            parentComponents: Array(components.dropLast()),
            parent: parent,
            leaf: leaf,
            targetDescriptor: target.descriptor,
            targetStatus: target.status
        )
    }

    private static func relativeComponents(
        for match: MacArtifactMatch
    ) throws -> (rootPath: String, components: [String]) {
        let rootPath = match.rootURL.standardizedFileURL.path
        let targetPath = match.url.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard rootPath != "/", targetPath.hasPrefix(rootPrefix) else {
            throw POSIXError(.EINVAL)
        }
        let components = String(targetPath.dropFirst(rootPrefix.count))
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw POSIXError(.EINVAL)
        }
        return (rootPath, components)
    }

    private static func openRootDescriptor(at path: String, device: UInt64) throws -> Int32 {
        let descriptor = path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let error = currentPOSIXError()
            _ = close(descriptor)
            throw error
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
              UInt64(status.st_dev) == device else {
            _ = close(descriptor)
            throw POSIXError(.ESTALE)
        }
        return descriptor
    }

    private static func openParentDirectories(
        _ components: [String],
        rootDescriptor: Int32,
        device: UInt64,
        descriptors: inout [Int32]
    ) throws -> Int32 {
        var parent = rootDescriptor
        for component in components {
            let descriptor = component.withCString {
                openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { throw currentPOSIXError() }
            descriptors.append(descriptor)
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { throw currentPOSIXError() }
            guard status.st_mode & S_IFMT == S_IFDIR,
                  UInt64(status.st_dev) == device else {
                throw POSIXError(.EXDEV)
            }
            parent = descriptor
        }
        return parent
    }

    private static func openTarget(
        _ leaf: String,
        in parent: Int32,
        match: MacArtifactMatch,
        descriptors: inout [Int32]
    ) throws -> (descriptor: Int32, status: stat) {
        var targetStatus = stat()
        guard leaf.withCString({
            fstatat(parent, $0, &targetStatus, AT_SYMLINK_NOFOLLOW)
        }) == 0 else {
            throw currentPOSIXError()
        }
        guard UInt64(targetStatus.st_dev) == match.rootDevice else { throw POSIXError(.EXDEV) }

        var targetFlags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        let expectedType = match.kind == .metadataDirectory ? S_IFDIR : S_IFREG
        if expectedType == S_IFDIR { targetFlags |= O_DIRECTORY }
        let descriptor = leaf.withCString { openat(parent, $0, targetFlags) }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        descriptors.append(descriptor)
        var openedStatus = stat()
        guard fstat(descriptor, &openedStatus) == 0,
              openedStatus.st_dev == targetStatus.st_dev,
              openedStatus.st_ino == targetStatus.st_ino,
              openedStatus.st_mode & S_IFMT == expectedType else {
            throw POSIXError(.ESTALE)
        }
        return (descriptor, openedStatus)
    }
    private static func fingerprint(
        at location: OpenedLocation,
        for match: MacArtifactMatch,
        sourceEntryMustMatch: Bool
    ) throws -> MacArtifactFingerprint? {
        var targetStatus = stat()
        guard fstat(location.targetDescriptor, &targetStatus) == 0,
              targetStatus.st_dev == location.targetStatus.st_dev,
              targetStatus.st_ino == location.targetStatus.st_ino,
              targetStatus.st_mode & S_IFMT == location.targetStatus.st_mode & S_IFMT else {
            return nil
        }
        if sourceEntryMustMatch {
            var pathStatus = stat()
            guard location.leaf.withCString({
                fstatat(location.parent, $0, &pathStatus, AT_SYMLINK_NOFOLLOW)
            }) == 0,
                  pathStatus.st_dev == targetStatus.st_dev,
                  pathStatus.st_ino == targetStatus.st_ino,
                  pathStatus.st_mode & S_IFMT == targetStatus.st_mode & S_IFMT else {
                return nil
            }
        }

        let entry = MacArtifactScanner.entry(for: targetStatus, path: match.url.path)
        switch match.kind {
        case .desktopDatabase:
            return MacArtifactFingerprint(entries: [entry])
        case .appleDoubleSidecar:
            guard isAppleDouble(descriptor: location.targetDescriptor, expected: targetStatus) else {
                return nil
            }
            var entries = [entry]
            let companionName = String(match.url.lastPathComponent.dropFirst(2))
            if !companionName.isEmpty {
                var companionStatus = stat()
                if companionName.withCString({
                    fstatat(location.parent, $0, &companionStatus, AT_SYMLINK_NOFOLLOW)
                }) == 0,
                   companionStatus.st_mode & S_IFMT == S_IFREG,
                   UInt64(companionStatus.st_dev) == match.rootDevice {
                    let companionPath = match.url.deletingLastPathComponent()
                        .appendingPathComponent(companionName).path
                    entries.append(MacArtifactScanner.entry(for: companionStatus, path: companionPath))
                }
            }
            return MacArtifactFingerprint(entries: entries.sorted { $0.path < $1.path })
        case .metadataDirectory:
            var entries: [MacArtifactFingerprint.Entry] = []
            try MacArtifactSafeDirectoryTraversal.fingerprintDirectory(
                at: location.targetDescriptor,
                path: match.url.path,
                device: match.rootDevice,
                entries: &entries
            )
            return MacArtifactFingerprint(entries: entries.sorted { $0.path < $1.path })
        }
    }

    private static func isAppleDouble(descriptor: Int32, expected: stat) -> Bool {
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == expected.st_dev,
              opened.st_ino == expected.st_ino,
              opened.st_mode & S_IFMT == S_IFREG else {
            return false
        }
        var header: UInt32 = 0
        let bytes = withUnsafeMutableBytes(of: &header) {
            pread(descriptor, $0.baseAddress, MemoryLayout<UInt32>.size, 0)
        }
        return bytes == MemoryLayout<UInt32>.size && UInt32(bigEndian: header) == 0x0005_1607
    }



    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
