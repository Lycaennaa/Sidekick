import AppKit

extension AppDelegate {
    func installMacArtifactCleanup() {
        let coordinator = MacArtifactCleanupCoordinator(store: macArtifactCleanupStore)
        coordinator.onRequestEnrollment = { [weak self] volume in
            guard let self,
                  self.macArtifactCleanupEnrollmentPrompts[volume.identifier] == nil else {
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            let prompt = MacArtifactCleanupPromptPanel(
                title: "Enroll \(volume.url.lastPathComponent) for Mac cleanup?",
                detail: [
                    "Sidekick recursively scans and monitors this volume while the app is open.",
                    "Matching files wait at least 30 seconds without observed changes before the selected action.",
                    "Volume path: \(volume.url.path)"
                ].joined(separator: " "),
                buttons: [
                    .init(title: "Enroll Volume", action: { [weak self] in
                        guard let self else { return }
                        _ = self.macArtifactCleanupStore.enrollExternalVolume(
                            volume.url,
                            volumeIdentifier: volume.identifier
                        )
                    }),
                    .init(title: "Not Now")
                ]
            )
            self.macArtifactCleanupEnrollmentPrompts[volume.identifier] = prompt
            prompt.onDismiss = { [weak self] in
                guard let self else { return }
                self.macArtifactCleanupEnrollmentPrompts.removeValue(forKey: volume.identifier)
            }
            let cascadeOffset = CGFloat((self.macArtifactCleanupEnrollmentPrompts.count - 1) % 6) * 24
            prompt.show(cascadeOffset: cascadeOffset)
        }
        macArtifactCleanupCoordinator = coordinator
        coordinator.start()
    }
}
