import AppKit
import DiskArbitration
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
            .volumeIsLocalKey,
            .volumeIsInternalKey,
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
                  let identity = MacArtifactCleanupRoot.currentVolumeIdentity(at: volume),
                  !identity.identifier.isEmpty else {
                return nil
            }
            if identity.isFuse {
                return MacArtifactMountedVolume(
                    url: volume.standardizedFileURL,
                    identifier: identity.identifier
                )
            }
            guard let values = try? volume.resourceValues(forKeys: keys),
                  values.volumeIsLocal == true,
                  values.volumeIsInternal == false,
                  values.volumeIsRemovable == true || values.volumeIsEjectable == true,
                  values.volumeUUIDString == identity.identifier,
                  Self.hasSupportedBackingDevice(at: volume) else {
                return nil
            }
            return MacArtifactMountedVolume(
                url: volume.standardizedFileURL,
                identifier: identity.identifier
            )
        }
    }

    static func supportsFolderEnrollment(
        at folderURL: URL,
        volumeIdentity: MacArtifactVolumeIdentity
    ) -> Bool {
        guard !volumeIdentity.identifier.isEmpty else { return false }
        if volumeIdentity.isFuse { return true }
        guard let values = try? folderURL.resourceValues(forKeys: [.volumeIsLocalKey]),
              values.volumeIsLocal == true else {
            return false
        }
        let volumeKeys: Set<URLResourceKey> = [.volumeUUIDStringKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(volumeKeys),
            options: []
        ) ?? []
        guard let volumeURL = volumes.first(where: { candidate in
            guard let candidateValues = try? candidate.resourceValues(forKeys: volumeKeys) else {
                return false
            }
            return candidateValues.volumeUUIDString == volumeIdentity.identifier
        }) else {
            return false
        }
        return hasSupportedBackingDevice(at: volumeURL)
    }

    private static func hasSupportedBackingDevice(at volumeURL: URL) -> Bool {
        guard let deviceProtocol = backingDeviceProtocol(at: volumeURL) else { return false }
        // Disk images use a virtual interface despite advertising removable/ejectable media.
        return deviceProtocol.caseInsensitiveCompare("Disk Image") != .orderedSame
            && deviceProtocol.caseInsensitiveCompare("Virtual Interface") != .orderedSame
    }

    private static func backingDeviceProtocol(at volumeURL: URL) -> String? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL),
              let description = DADiskCopyDescription(disk) else {
            return nil
        }
        return (description as NSDictionary)[kDADiskDescriptionDeviceProtocolKey] as? String
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
