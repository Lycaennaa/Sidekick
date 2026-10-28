import AppKit
import Foundation
import UserNotifications

@MainActor
final class MacArtifactCleanupCoordinator {
    let store: MacArtifactCleanupStore
    var onRequestEnrollment: ((MacArtifactMountedVolume) -> Void)?
    var onChange: (() -> Void)?

    private let volumeMonitor = MacArtifactVolumeMonitor()
    private let fileWatcher = MacArtifactFileWatcher()
    private let processor: MacArtifactCleanupProcessor
    private var running = false
    private var observedConfiguration: MacArtifactCleanupConfiguration
    private var activeRoots: [UUID: MacArtifactCleanupRoot] = [:]
    private var promptedVolumeIdentifiers: Set<String> = []

    init(store: MacArtifactCleanupStore) {
        self.store = store
        observedConfiguration = store.configuration
        processor = MacArtifactCleanupProcessor(
            store: store,
            notifier: MacArtifactCleanupNotifier()
        )
        processor.onChange = { [weak self] in self?.onChange?() }
        processor.onRootChanged = { [weak self] in self?.refreshRoots() }
        fileWatcher.onEvents = { [weak self] events in self?.processor.receive(events) }
    }

    func start() {
        guard !running else { return }
        running = true
        observedConfiguration = store.configuration
        store.onChange = { [weak self] in self?.storeDidChange() }
        volumeMonitor.onMount = { [weak self] volume in
            guard let self else { return }
            self.requestEnrollmentIfNeeded(for: volume)
            self.refreshRoots()
        }
        volumeMonitor.onUnmount = { [weak self] in self?.refreshRoots() }
        volumeMonitor.start()

        activeRoots = Dictionary(uniqueKeysWithValues: resolveActiveRoots().map { ($0.id, $0) })
        // FSEvents starts at SinceNow; establish that boundary before the initial scans.
        startWatchingActiveRoots()
        processor.start(roots: Array(activeRoots.values))
        for volume in volumeMonitor.mountedExternalVolumes() {
            requestEnrollmentIfNeeded(for: volume)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        store.onChange = nil
        volumeMonitor.stop()
        volumeMonitor.onMount = nil
        volumeMonitor.onUnmount = nil
        fileWatcher.stop()
        processor.stop()
        onChange?()
    }

    func preview(rootID: UUID) async throws -> MacArtifactScanResult {
        try await processor.preview(rootID: rootID)
    }

    @discardableResult
    func applyManually(
        _ matches: [MacArtifactMatch],
        rootID: UUID,
        mode: MacArtifactRemovalMode
    ) -> MacArtifactCleanupHistoryEntry? {
        processor.applyManually(matches, rootID: rootID, mode: mode)
    }

    private func storeDidChange() {
        if observedConfiguration != store.configuration {
            observedConfiguration = store.configuration
            refreshRoots()
        }
        onChange?()
    }

    private func refreshRoots() {
        guard running else { return }
        activeRoots = Dictionary(uniqueKeysWithValues: resolveActiveRoots().map { ($0.id, $0) })
        startWatchingActiveRoots()
        // Watch the updated roots before rescanning them so intervening changes are observed.
        processor.updateRoots(Array(activeRoots.values))
        onChange?()
    }

    private func startWatchingActiveRoots() {
        fileWatcher.stop()
        let roots = activeRoots.values.map(\.url)
        if roots.isEmpty {
            return
        }
        fileWatcher.start(watching: roots)
    }

    private func resolveActiveRoots() -> [MacArtifactCleanupRoot] {
        let mounted = volumeMonitor.mountedExternalVolumes()
        return store.configuration.roots.compactMap { root in
            switch root.kind {
            case .folder:
                guard FileManager.default.fileExists(atPath: root.path),
                      root.isOnOriginalVolume else {
                    return nil
                }
                return root
            case .externalVolume:
                guard let identifier = root.volumeIdentifier,
                      let volume = mounted.first(where: { $0.identifier == identifier }) else {
                    return nil
                }
                return MacArtifactCleanupRoot(
                    id: root.id,
                    path: volume.url.path,
                    kind: .externalVolume,
                    volumeIdentifier: identifier,
                    modeOverride: root.modeOverride
                )
            }
        }
    }

    private func requestEnrollmentIfNeeded(for volume: MacArtifactMountedVolume) {
        guard !promptedVolumeIdentifiers.contains(volume.identifier),
                  !store.configuration.roots.contains(where: {
                      $0.kind == .externalVolume && $0.volumeIdentifier == volume.identifier
                  }) else {
            return
        }
        promptedVolumeIdentifiers.insert(volume.identifier)
        onRequestEnrollment?(volume)
    }
}
