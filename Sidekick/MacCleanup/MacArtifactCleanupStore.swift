import CryptoKit
import Darwin
import Foundation

nonisolated struct MacArtifactVolumeIdentity: Sendable {
    let identifier: String
    let isFuse: Bool
    let legacyIdentifier: String?
}

nonisolated struct MacArtifactCleanupRoot: Codable, Equatable, Identifiable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case folder
        case externalVolume
    }

    let id: UUID
    let path: String
    var kind: Kind
    var volumeIdentifier: String?
    var modeOverride: MacArtifactRemovalMode?

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { url.lastPathComponent.isEmpty ? path : url.lastPathComponent }
    static func containing<Roots: Sequence>(
        path: String,
        in roots: Roots
    ) -> MacArtifactCleanupRoot? where Roots.Element == MacArtifactCleanupRoot {
        var bestMatch: MacArtifactCleanupRoot?
        for root in roots {
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard path == root.path || path.hasPrefix(rootPath) else { continue }
            guard let current = bestMatch else {
                bestMatch = root
                continue
            }
            if root.path.count > current.path.count {
                bestMatch = root
            }
        }
        return bestMatch
    }

    var isOnOriginalVolume: Bool {
        guard let volumeIdentifier, !volumeIdentifier.isEmpty else { return false }
        return Self.currentVolumeIdentifier(at: url) == volumeIdentifier
    }

    mutating func migrateLegacyFuseVolumeIdentifier(
        using identity: MacArtifactVolumeIdentity
    ) -> Bool {
        guard identity.isFuse,
              let legacyIdentifier = identity.legacyIdentifier,
              volumeIdentifier == legacyIdentifier,
              volumeIdentifier != identity.identifier else {
            return false
        }
        volumeIdentifier = identity.identifier
        return true
    }

    static func currentVolumeIdentity(at url: URL) -> MacArtifactVolumeIdentity? {
        let volumeUUIDString = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        let fileSystem = fileSystemInfo(at: url)
        return resolveVolumeIdentity(
            volumeUUIDString: volumeUUIDString,
            fileSystemType: fileSystem?.type,
            source: fileSystem?.source,
            mountPoint: fileSystem?.mountPoint
        )
    }

    static func resolveVolumeIdentity(
        volumeUUIDString: String?,
        fileSystemType: String?,
        source: String?,
        mountPoint: String?
    ) -> MacArtifactVolumeIdentity? {
        let volumeUUIDString = volumeUUIDString.flatMap { $0.isEmpty ? nil : $0 }
        if let fileSystemType {
            let type = fileSystemType.lowercased()
            if isFuseFileSystem(type) {
                guard let identifier = fuseIdentifier(
                    type: type,
                    source: source ?? "",
                    mountPoint: mountPoint ?? ""
                ) else {
                    return nil
                }
                return MacArtifactVolumeIdentity(
                    identifier: identifier,
                    isFuse: true,
                    legacyIdentifier: volumeUUIDString
                )
            }
        }
        guard let volumeUUIDString else { return nil }
        return MacArtifactVolumeIdentity(
            identifier: volumeUUIDString,
            isFuse: false,
            legacyIdentifier: nil
        )
    }

    static func currentVolumeIdentifier(at url: URL) -> String? {
        currentVolumeIdentity(at: url)?.identifier
    }

    private struct FileSystemInfo {
        let type: String
        let source: String
        let mountPoint: String
    }

    static func fuseIdentifier(type: String, source: String, mountPoint: String) -> String? {
        guard !source.isEmpty, !mountPoint.isEmpty else { return nil }
        var material = Data()
        material.append(contentsOf: type.utf8)
        material.append(0)
        material.append(contentsOf: source.utf8)
        material.append(0)
        material.append(contentsOf: mountPoint.utf8)
        let digest = SHA256.hash(data: material)
        return "fuse:\(Data(digest).base64EncodedString())"
    }

    private static func fileSystemInfo(at url: URL) -> FileSystemInfo? {
        var status = statfs()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return statfs(path, &status)
        }
        guard result == 0 else { return nil }
        return FileSystemInfo(
            type: cString(from: &status.f_fstypename).lowercased(),
            source: cString(from: &status.f_mntfromname),
            mountPoint: cString(from: &status.f_mntonname)
        )
    }

    private static func cString<Field>(from field: inout Field) -> String {
        let capacity = MemoryLayout<Field>.size
        return withUnsafePointer(to: &field) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    static func isFuseFileSystem(_ type: String) -> Bool {
        type == "macfuse" || type == "osxfuse"
            || type.hasPrefix("macfuse_")
            || type.hasPrefix("osxfuse_")
            || type.hasPrefix("fuse")
    }
}

nonisolated struct MacArtifactCleanupConfiguration: Codable, Equatable, Sendable {
    var defaultMode: MacArtifactRemovalMode
    var roots: [MacArtifactCleanupRoot]

    static let initial = MacArtifactCleanupConfiguration(
        defaultMode: .deletePermanently,
        roots: []
    )

    func mode(for root: MacArtifactCleanupRoot) -> MacArtifactRemovalMode {
        root.modeOverride ?? defaultMode
    }
}

nonisolated struct MacArtifactCleanupHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let rootPath: String
    let mode: MacArtifactRemovalMode
    let matchedCount: Int
    let removedCount: Int
    let skippedCount: Int
    let details: [String]

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        rootPath: String,
        mode: MacArtifactRemovalMode,
        matchedCount: Int,
        removedCount: Int,
        skippedCount: Int,
        details: [String]
    ) {
        self.id = id
        self.date = date
        self.rootPath = rootPath
        self.mode = mode
        self.matchedCount = matchedCount
        self.removedCount = removedCount
        self.skippedCount = skippedCount
        self.details = details
    }
}

@MainActor
final class MacArtifactCleanupStore {
    static let historyLimit = 50

    private enum Key {
        static let configuration = "macArtifactCleanupConfiguration"
        static let history = "macArtifactCleanupHistory"
    }

    private let defaults: UserDefaults
    private(set) var configuration: MacArtifactCleanupConfiguration
    private(set) var history: [MacArtifactCleanupHistoryEntry]
    var onChange: (() -> Void)?

    init(
        defaults: UserDefaults = .standard,
        volumeIdentityAt: (URL) -> MacArtifactVolumeIdentity? = {
            MacArtifactCleanupRoot.currentVolumeIdentity(at: $0)
        }
    ) {
        self.defaults = defaults
        configuration = Self.decode(
            MacArtifactCleanupConfiguration.self,
            forKey: Key.configuration,
            in: defaults
        ) ?? .initial
        history = Array(Self.decode(
            [MacArtifactCleanupHistoryEntry].self,
            forKey: Key.history,
            in: defaults
        )?.prefix(Self.historyLimit) ?? [])
        migrateLegacyFuseIdentifiers(volumeIdentityAt: volumeIdentityAt)
    }

    @discardableResult
    func addFolder(_ url: URL) -> Bool {
        guard let volumeIdentity = MacArtifactCleanupRoot.currentVolumeIdentity(at: url),
              MacArtifactVolumeMonitor.supportsFolderEnrollment(
                at: url,
                volumeIdentity: volumeIdentity
              ) else {
            return false
        }
        return addRoot(url, kind: .folder, volumeIdentifier: volumeIdentity.identifier)
    }

    @discardableResult
    func enrollExternalVolume(_ url: URL, volumeIdentifier: String?) -> Bool {
        guard let volumeIdentifier, !volumeIdentifier.isEmpty else { return false }
        guard !configuration.roots.contains(where: {
            $0.kind == .externalVolume && $0.volumeIdentifier == volumeIdentifier
        }) else {
            return false
        }
        return addRoot(url, kind: .externalVolume, volumeIdentifier: volumeIdentifier)
    }

    func removeRoot(id: UUID) {
        let updatedRoots = configuration.roots.filter { $0.id != id }
        guard updatedRoots.count != configuration.roots.count else { return }
        configuration.roots = updatedRoots
        saveConfiguration()
    }

    func setDefaultMode(_ mode: MacArtifactRemovalMode) {
        guard configuration.defaultMode != mode else { return }
        configuration.defaultMode = mode
        saveConfiguration()
    }

    func setModeOverride(_ mode: MacArtifactRemovalMode?, forRootID id: UUID) {
        guard let index = configuration.roots.firstIndex(where: { $0.id == id }),
              configuration.roots[index].modeOverride != mode else {
            return
        }
        configuration.roots[index].modeOverride = mode
        saveConfiguration()
    }

    func record(_ entry: MacArtifactCleanupHistoryEntry) {
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        saveHistory()
    }

    private func addRoot(_ url: URL, kind: MacArtifactCleanupRoot.Kind, volumeIdentifier: String?) -> Bool {
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.path != "/" else { return false }
        if let existingIndex = configuration.roots.firstIndex(where: {
            $0.path == standardizedURL.path && $0.volumeIdentifier == volumeIdentifier
        }) {
            if kind == .externalVolume,
               configuration.roots[existingIndex].kind == .folder {
                configuration.roots[existingIndex].kind = .externalVolume
                saveConfiguration()
                return true
            }
            return false
        }
        configuration.roots.append(
            MacArtifactCleanupRoot(
                id: UUID(),
                path: standardizedURL.path,
                kind: kind,
                volumeIdentifier: volumeIdentifier,
                modeOverride: nil
            )
        )
        saveConfiguration()
        return true
    }

    private func migrateLegacyFuseIdentifiers(
        volumeIdentityAt: (URL) -> MacArtifactVolumeIdentity?
    ) {
        var didMigrate = false
        for index in configuration.roots.indices {
            guard let identity = volumeIdentityAt(configuration.roots[index].url),
                  configuration.roots[index].migrateLegacyFuseVolumeIdentifier(using: identity) else {
                continue
            }
            didMigrate = true
        }
        if didMigrate {
            persist(configuration, forKey: Key.configuration)
        }
    }

    private func saveConfiguration() {
        persist(configuration, forKey: Key.configuration)
        onChange?()
    }

    private func saveHistory() {
        persist(history, forKey: Key.history)
        onChange?()
    }

    private func persist<Value: Encodable>(_ value: Value, forKey key: String) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            NSLog("Could not save Mac cleanup settings: %@", error.localizedDescription)
        }
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        forKey key: String,
        in defaults: UserDefaults
    ) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            NSLog("Could not load Mac cleanup settings: %@", error.localizedDescription)
            defaults.removeObject(forKey: key)
            return nil
        }
    }
}
