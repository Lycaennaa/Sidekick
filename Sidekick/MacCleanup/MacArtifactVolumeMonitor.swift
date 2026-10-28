import AppKit
import Foundation

struct MacArtifactMountedVolume: Equatable, Sendable {
    let url: URL
    let identifier: String
}

@MainActor
final class MacArtifactVolumeMonitor {
    var onMount: ((MacArtifactMountedVolume) -> Void)?
    var onUnmount: (() -> Void)?

    private let notifications = NSWorkspace.shared.notificationCenter
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        observers.append(notifications.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor [weak self] in self?.handleMount(url) }
        })
        observers.append(notifications.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onUnmount?() }
        })
    }

    func stop() {
        for observer in observers { notifications.removeObserver(observer) }
        observers.removeAll()
    }

    func mountedExternalVolumes() -> [MacArtifactMountedVolume] {
        let keys: Set<URLResourceKey> = [
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeUUIDStringKey
        ]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: []
        ) ?? []
        return volumes.compactMap { volume in
            guard !volume.standardizedFileURL.path.hasPrefix("/private/var/run/com.apple.security.cryptexd/mnt/"),
                  let values = try? volume.resourceValues(forKeys: keys),
                  values.volumeIsRemovable == true || values.volumeIsEjectable == true,
                  let identifier = values.volumeUUIDString,
                  !identifier.isEmpty else {
                return nil
            }
            return MacArtifactMountedVolume(url: volume.standardizedFileURL, identifier: identifier)
        }
    }

    private func handleMount(_ url: URL) {
        guard let volume = mountedExternalVolumes().first(where: {
            $0.url.standardizedFileURL.path == url.standardizedFileURL.path
        }) else {
            return
        }
        onMount?(volume)
    }
}
