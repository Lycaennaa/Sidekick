import Foundation

nonisolated struct MacArtifactCleanupRoot: Codable, Equatable, Identifiable, Sendable {
    nonisolated enum Kind: String, Codable, Sendable {
        case folder
        case externalVolume
    }

    let id: UUID
    let path: String
    var kind: Kind
    let volumeIdentifier: String?
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

    static func currentVolumeIdentifier(at url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]),
              let identifier = values.volumeUUIDString,
              !identifier.isEmpty else {
            return nil
        }
        return identifier
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

    init(defaults: UserDefaults = .standard) {
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
    }

    @discardableResult
    func addFolder(_ url: URL) -> Bool {
        guard let volumeIdentifier = MacArtifactCleanupRoot.currentVolumeIdentifier(at: url) else {
            return false
        }
        return addRoot(url, kind: .folder, volumeIdentifier: volumeIdentifier)
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
