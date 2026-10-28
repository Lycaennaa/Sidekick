import Darwin
import Foundation

nonisolated enum MacArtifactKind: String, Codable, CaseIterable, Sendable {
    case desktopDatabase
    case appleDoubleSidecar
    case metadataDirectory
}

nonisolated struct MacArtifactFingerprint: Equatable, Sendable {
    nonisolated struct Entry: Equatable, Sendable {
        let path: String
        let device: UInt64
        let inode: UInt64
        let mode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    let entries: [Entry]
}

nonisolated struct MacArtifactMatch: Equatable, Sendable, Identifiable {
    let url: URL
    let rootURL: URL
    let rootDevice: UInt64
    let kind: MacArtifactKind
    let fingerprint: MacArtifactFingerprint

    var id: String { url.standardizedFileURL.path }
    static func cleanupPrecedes(_ lhs: Self, _ rhs: Self) -> Bool {
        let lhsIsSidecar = lhs.kind == .appleDoubleSidecar
        let rhsIsSidecar = rhs.kind == .appleDoubleSidecar
        if lhsIsSidecar != rhsIsSidecar { return lhsIsSidecar }
        return lhs.url.path < rhs.url.path
    }
}

nonisolated struct MacArtifactScanIssue: Equatable, Sendable {
    let path: String
    let reason: String
}

nonisolated struct MacArtifactScanResult: Equatable, Sendable {
    let matches: [MacArtifactMatch]
    let issues: [MacArtifactScanIssue]
}

nonisolated enum MacArtifactRemovalMode: String, Codable, CaseIterable, Sendable {
    case previewOnly
    case moveToTrash
    case deletePermanently
}

nonisolated enum MacArtifactRemovalResult: Equatable, Sendable {
    case previewed
    case movedToTrash(URL)
    case deleted
    case changedSinceScan
    case failed(String)
}

nonisolated enum MacArtifactScanner {
    private struct FileInfo {
        let entry: MacArtifactFingerprint.Entry
        let isDirectory: Bool
        let isRegularFile: Bool
        let isSymbolicLink: Bool
    }

    static func scan(root: URL) throws -> MacArtifactScanResult {
        let root = root.standardizedFileURL
        guard root.path != "/" else { throw ScanError.unsafeRoot }
        guard let rootInfo = fileInfo(at: root),
              rootInfo.isDirectory,
              !rootInfo.isSymbolicLink else {
            throw ScanError.invalidRoot
        }
        guard !isPackage(root) else { throw ScanError.packageRoot }

        let result = try scanDirectories(root: root, device: rootInfo.entry.device)
        return MacArtifactScanResult(
            matches: result.matches.sorted(by: MacArtifactMatch.cleanupPrecedes),
            issues: result.issues.sorted { $0.path < $1.path }
        )
    }

    private enum ScanDisposition {
        case match(MacArtifactMatch)
        case descend(URL)
        case ignore
        case issue(MacArtifactScanIssue)
    }

    private static func scanDirectories(
        root: URL,
        device: UInt64
    ) throws -> (matches: [MacArtifactMatch], issues: [MacArtifactScanIssue]) {
        var pendingDirectories = [root]
        var matches: [MacArtifactMatch] = []
        var issues: [MacArtifactScanIssue] = []
        while let directory = pendingDirectories.popLast() {
            try Task.checkCancellation()
            let children: [URL]
            do {
                children = try directoryContents(at: directory)
            } catch {
                issues.append(MacArtifactScanIssue(path: directory.path, reason: error.localizedDescription))
                continue
            }
            for child in children {
                try Task.checkCancellation()
                switch inspectChild(child, root: root, device: device) {
                case .match(let match): matches.append(match)
                case .descend(let url): pendingDirectories.append(url)
                case .ignore: break
                case .issue(let issue): issues.append(issue)
                }
            }
        }
        return (matches, issues)
    }

    private static func inspectChild(_ child: URL, root: URL, device: UInt64) -> ScanDisposition {
        guard let info = fileInfo(at: child) else {
            return .issue(MacArtifactScanIssue(path: child.path, reason: "Could not inspect item."))
        }
        guard !info.isSymbolicLink, info.entry.device == device else { return .ignore }
        if let kind = matchedKind(for: child.lastPathComponent, info: info) {
            do {
                guard let match = try makeMatch(
                    at: child,
                    root: root,
                    device: device,
                    info: info,
                    kind: kind
                ) else {
                    return .ignore
                }
                return .match(match)
            } catch {
                return .issue(MacArtifactScanIssue(path: child.path, reason: error.localizedDescription))
            }
        }
        return info.isDirectory && !isPackage(child) ? .descend(child) : .ignore
    }

    private static func makeMatch(
        at url: URL,
        root: URL,
        device: UInt64,
        info: FileInfo,
        kind: MacArtifactKind
    ) throws -> MacArtifactMatch? {
        guard !(info.isDirectory && isPackage(url)) else { throw ScanError.containsPackage }
        let fingerprint: MacArtifactFingerprint
        if info.isDirectory {
            fingerprint = try directoryFingerprint(at: url, device: device)
        } else if kind == .appleDoubleSidecar {
            guard isAppleDouble(at: url, expected: info.entry) else { return nil }
            fingerprint = try sidecarFingerprint(at: url, device: device, entry: info.entry)
        } else {
            fingerprint = MacArtifactFingerprint(entries: [info.entry])
        }
        return MacArtifactMatch(url: url, rootURL: root, rootDevice: device, kind: kind, fingerprint: fingerprint)
    }
    static func match(at url: URL, within root: URL) throws -> MacArtifactMatch? {
        let root = root.standardizedFileURL
        let url = url.standardizedFileURL
        guard let device = try validatedRootDevice(for: url, within: root),
              let info = fileInfo(at: url),
              !info.isSymbolicLink,
              info.entry.device == device,
              let kind = matchedKind(for: url.lastPathComponent, info: info) else {
            return nil
        }
        return try makeMatch(at: url, root: root, device: device, info: info, kind: kind)
    }
    static func fingerprint(for match: MacArtifactMatch) throws -> MacArtifactFingerprint {
        guard let device = try validatedRootDevice(for: match.url, within: match.rootURL),
              device == match.rootDevice,
              let info = fileInfo(at: match.url),
              !info.isSymbolicLink,
              info.entry.device == device else {
            throw ScanError.itemUnavailable
        }

        switch match.kind {
        case .desktopDatabase:
            guard info.isRegularFile else { throw ScanError.itemUnavailable }
            return MacArtifactFingerprint(entries: [info.entry])
        case .appleDoubleSidecar:
            guard info.isRegularFile, isAppleDouble(at: match.url, expected: info.entry) else {
                throw ScanError.itemUnavailable
            }
            return try sidecarFingerprint(at: match.url, device: device, entry: info.entry)
        case .metadataDirectory:
            guard info.isDirectory else { throw ScanError.itemUnavailable }
            return try directoryFingerprint(at: match.url, device: device)
        }
    }

    static func mayMatch(_ name: String) -> Bool {
        name == ".DS_Store"
            || name == "__MACOSX"
            || name == ".AppleDouble"
            || name.hasPrefix("._")
    }
    private static func matchedKind(for name: String, info: FileInfo) -> MacArtifactKind? {
        if name == ".DS_Store", info.isRegularFile {
            return .desktopDatabase
        }
        if name == "__MACOSX" || name == ".AppleDouble", info.isDirectory {
            return .metadataDirectory
        }
        if name.hasPrefix("._"), info.isRegularFile {
            return .appleDoubleSidecar
        }
        return nil
    }

    private static func sidecarFingerprint(
        at sidecar: URL,
        device: UInt64,
        entry: MacArtifactFingerprint.Entry
    ) throws -> MacArtifactFingerprint {
        guard entry.device == device else { throw ScanError.itemUnavailable }
        var entries = [entry]
        let companionName = String(sidecar.lastPathComponent.dropFirst(2))
        if !companionName.isEmpty {
            let companion = sidecar.deletingLastPathComponent().appendingPathComponent(companionName)
            if let companionInfo = fileInfo(at: companion),
               companionInfo.isRegularFile,
               !companionInfo.isSymbolicLink,
               companionInfo.entry.device == device {
                entries.append(companionInfo.entry)
            }
        }
        return MacArtifactFingerprint(entries: entries.sorted { $0.path < $1.path })
    }

    private static func directoryFingerprint(at root: URL, device: UInt64) throws -> MacArtifactFingerprint {
        var pendingDirectories = [root]
        var entries: [MacArtifactFingerprint.Entry] = []

        while let directory = pendingDirectories.popLast() {
            try Task.checkCancellation()
            guard let directoryInfo = fileInfo(at: directory),
                  directoryInfo.isDirectory,
                  !directoryInfo.isSymbolicLink else {
                throw ScanError.itemUnavailable
            }
            guard directoryInfo.entry.device == device else { throw ScanError.crossedVolume }
            if directory != root, isPackage(directory) {
                throw ScanError.containsPackage
            }
            entries.append(directoryInfo.entry)

            let children: [URL]
            do {
                children = try directoryContents(at: directory)
            } catch {
                throw ScanError.unreadableDirectory
            }

            for child in children {
                try Task.checkCancellation()
                guard let info = fileInfo(at: child) else { throw ScanError.itemUnavailable }
                guard info.entry.device == device else { throw ScanError.crossedVolume }
                entries.append(info.entry)
                if info.isDirectory, !info.isSymbolicLink {
                    if isPackage(child) { throw ScanError.containsPackage }
                    pendingDirectories.append(child)
                }
            }
        }

        return MacArtifactFingerprint(entries: entries.sorted { $0.path < $1.path })
    }

    private static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return url.path == root.path || url.path.hasPrefix(rootPath)
    }

    private static func validatedRootDevice(for url: URL, within root: URL) throws -> UInt64? {
        let root = root.standardizedFileURL
        let url = url.standardizedFileURL
        guard root.path != "/", isContained(url, in: root) else { return nil }
        guard let rootInfo = fileInfo(at: root),
              rootInfo.isDirectory,
              !rootInfo.isSymbolicLink else {
            throw ScanError.invalidRoot
        }
        guard !isPackage(root) else { return nil }

        var ancestor = url.deletingLastPathComponent()
        while ancestor.path != root.path {
            guard isContained(ancestor, in: root),
                  let info = fileInfo(at: ancestor),
                  info.isDirectory,
                  !info.isSymbolicLink,
                  info.entry.device == rootInfo.entry.device,
                  !isPackage(ancestor) else {
                return nil
            }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return nil }
            ancestor = parent
        }
        return rootInfo.entry.device
    }
    private static func directoryContents(at url: URL) throws -> [URL] {
        guard let directory = url.path.withCString({ opendir($0) }) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = closedir(directory) }

        var children: [URL] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                let errorCode = errno
                if errorCode != 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
                }
                break
            }
            let nameCapacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: nameCapacity) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            children.append(url.appendingPathComponent(name))
        }
        return children.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private static func fileInfo(at url: URL) -> FileInfo? {
        var status = stat()
        let result = url.path.withCString { lstat($0, &status) }
        guard result == 0 else { return nil }

        let mode = status.st_mode & S_IFMT
        let entry = MacArtifactFingerprint.Entry(
            path: url.path,
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt64(status.st_mode),
            size: Int64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changeSeconds: Int64(status.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
        return FileInfo(
            entry: entry,
            isDirectory: mode == S_IFDIR,
            isRegularFile: mode == S_IFREG,
            isSymbolicLink: mode == S_IFLNK
        )
    }

    // Avoid LaunchServices-backed package queries from the background filesystem scanner.
    private static let packageDirectoryExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "prefpane",
        "qlgenerator", "mdimporter", "service", "workflow", "pages", "numbers", "key",
        "rtfd", "photolibrary", "photoslibrary", "imovielibrary", "fcpbundle", "band",
        "logicx", "garageband", "playground", "xcworkspace", "xcodeproj", "xcassets",
        "sparsebundle", "pkg", "scptd"
    ]

    static func isPackage(_ url: URL) -> Bool {
        packageDirectoryExtensions.contains(url.pathExtension.lowercased())
    }

    private static func isAppleDouble(at url: URL, expected: MacArtifactFingerprint.Entry) -> Bool {
        let descriptor = url.path.withCString { open($0, O_RDONLY) }
        guard descriptor >= 0 else { return false }
        defer { _ = close(descriptor) }

        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              UInt64(opened.st_dev) == expected.device,
              UInt64(opened.st_ino) == expected.inode,
              opened.st_mode & S_IFMT == S_IFREG else {
            return false
        }

        var header: UInt32 = 0
        guard read(descriptor, &header, MemoryLayout<UInt32>.size) == MemoryLayout<UInt32>.size else {
            return false
        }
        return UInt32(bigEndian: header) == 0x0005_1607
    }

    static func entry(for status: stat, path: String) -> MacArtifactFingerprint.Entry {
        MacArtifactFingerprint.Entry(
            path: path,
            device: UInt64(status.st_dev),
            inode: UInt64(status.st_ino),
            mode: UInt64(status.st_mode),
            size: Int64(status.st_size),
            modificationSeconds: Int64(status.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
            changeSeconds: Int64(status.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(status.st_ctimespec.tv_nsec)
        )
    }

    private enum ScanError: LocalizedError {
        case unsafeRoot
        case invalidRoot
        case packageRoot
        case itemUnavailable
        case crossedVolume
        case containsPackage
        case unreadableDirectory

        var errorDescription: String? {
            switch self {
            case .unsafeRoot: "The filesystem root cannot be selected for automatic cleanup."
            case .invalidRoot: "The selected root is unavailable or is not a real directory."
            case .packageRoot: "Package directories are not scanned."
            case .itemUnavailable: "The item changed or became unavailable during the scan."
            case .crossedVolume: "Cleanup would cross into another mounted volume."
            case .containsPackage: "The metadata directory contains a package and was left untouched."
            case .unreadableDirectory: "The metadata directory could not be read safely."
            }
        }
    }
}

enum MacArtifactCleaner {
    static func apply(
        _ match: MacArtifactMatch,
        mode: MacArtifactRemovalMode
    ) -> MacArtifactRemovalResult {
        guard mode != .previewOnly else { return .previewed }
        do {
            switch mode {
            case .previewOnly:
                return .previewed
            case .moveToTrash:
                guard let resultingURL = try MacArtifactSafeFileSystem.moveToTrash(match) else {
                    return .changedSinceScan
                }
                return .movedToTrash(resultingURL)
            case .deletePermanently:
                guard try MacArtifactSafeFileSystem.remove(match) else { return .changedSinceScan }
                return .deleted
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
