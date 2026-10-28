import AppKit

extension AppDelegate {
    func installMacArtifactCleanup() {
        let coordinator = MacArtifactCleanupCoordinator(store: macArtifactCleanupStore)
        coordinator.onRequestEnrollment = { [weak self] volume in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Enroll \(volume.url.lastPathComponent) for Mac cleanup?"
            alert.informativeText = [
                "Sidekick recursively scans and monitors this drive while the app is open.",
                "Matching files wait at least 30 seconds without observed changes before the selected action."
            ].joined(separator: " ")
            alert.addButton(withTitle: "Enroll Drive")
            alert.addButton(withTitle: "Not Now")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            _ = self.macArtifactCleanupStore.enrollExternalVolume(
                volume.url,
                volumeIdentifier: volume.identifier
            )
        }
        macArtifactCleanupCoordinator = coordinator
        coordinator.start()
    }
}
