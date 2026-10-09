import AppKit

@MainActor
final class DiscordInstallerView: NSView {
    private let coordinator = DiscordInstallerCoordinator()
    private let targetLabel = NSTextField(wrappingLabelWithString: "No Discord-compatible app selected.")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Choose a Discord-compatible app.")
    private let appPicker = DiscordTargetPickerView()
    private let installButton = NSButton(title: "Install Equicord", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Restore Discord", target: nil, action: nil)
    private let sourceBuildButton = NSButton(title: "Install Dev Version from Source", target: nil, action: nil)
    private let openSourceButton = NSButton(title: "Open Source Folder", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private var selectedTarget: DiscordInstallTarget? { appPicker.selectedTarget }
    private var activeTask: Task<Void, Never>?
    private var isBusy = false
    private var isShuttingDown = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildView()
        appPicker.onSelectionChanged = { [weak self] in self?.refreshState() }
        appPicker.onError = { [weak self] error in self?.showError(error) }
        refreshState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func refresh() {
        appPicker.refresh()
    }

    func cancelForApplicationTermination() -> Task<Void, Never>? {
        isShuttingDown = true
        updateControls()
        guard let activeTask else { return nil }
        activeTask.cancel()
        coordinator.cancelActiveOperation()
        return activeTask
    }

    private func buildView() {
        let title = NSTextField(labelWithString: "Discord")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.alignment = .left

        let explanation = NSTextField(wrappingLabelWithString: """
            Install the prebuilt release by default, or build Equicord's dev mode from a shallow source checkout.
            Source and dependencies stay in Application Support so you can edit and rebuild later.
            Source builds require Git, Node.js 22 or newer, and pnpm 12.8.1.
            """)
        explanation.textColor = .secondaryLabelColor
        explanation.alignment = .left

        targetLabel.alignment = .left
        statusLabel.alignment = .left
        statusLabel.textColor = .secondaryLabelColor

        openSourceButton.target = self
        openSourceButton.action = #selector(openEquicordSource)
        sourceBuildButton.target = self
        sourceBuildButton.action = #selector(buildDevFromSource)
        installButton.target = self
        installButton.action = #selector(installEquicord)
        restoreButton.target = self
        restoreButton.action = #selector(restoreDiscord)
        cancelButton.target = self
        cancelButton.action = #selector(cancelDownload)
        cancelButton.isHidden = true

        let sourceRow = NSStackView(views: [appPicker, openSourceButton])
        let installRow = NSStackView(views: [installButton, sourceBuildButton])
        let restoreRow = NSStackView(views: [restoreButton, cancelButton])
        for row in [sourceRow, installRow, restoreRow] {
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = 8
        }

        let stack = NSStackView(views: [
            title, explanation, targetLabel, sourceRow, installRow, restoreRow, statusLabel
        ])
        stack.orientation = .vertical
        configureSettingsPageStack(stack)
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @objc private func installEquicord() {
        guard !isShuttingDown, let selectedTarget else { return }
        if DiscordAppPatcher.state(for: selectedTarget) == .backupNameRepairRequired {
            guard confirmBackupNameRepair() else { return }
            isBusy = true
            updateControls()
            statusLabel.stringValue = "Repairing Equicord's original archive path…"

            let coordinator = self.coordinator
            activeTask = Task { [weak self, coordinator] in
                do {
                    try await coordinator.repairBackupName(target: selectedTarget)
                    self?.finishOperation(message: "Equicord is repaired. Relaunch Discord to load it.")
                } catch {
                    self?.finishOperation(error: error)
                }
            }
            return
        }

        guard confirmInstall() else { return }
        isBusy = true
        updateControls()
        statusLabel.stringValue = "Downloading and validating the official Equicord release…"

        let coordinator = self.coordinator
        activeTask = Task { [weak self, coordinator] in
            do {
                let version = try await coordinator.install(target: selectedTarget)
                self?.finishOperation(message: "Equicord \(version) installed. Relaunch Discord to load it.")
            } catch is CancellationError {
                self?.finishOperation(message: "Installation cancelled; Discord was not patched.")
            } catch {
                self?.finishOperation(error: error)
            }
        }
    }

    @objc private func buildDevFromSource() {
        guard !isShuttingDown, let selectedTarget, confirmSourceBuild() else { return }
        isBusy = true
        updateControls()
        statusLabel.stringValue = "Preparing Equicord source build…"

        let coordinator = self.coordinator
        activeTask = Task { [weak self, coordinator] in
            do {
                let version = try await coordinator.buildDevFromSource(target: selectedTarget) { [weak self] stage in
                    self?.statusLabel.stringValue = stage
                }
                self?.finishOperation(message: """
                    Equicord dev version \(version) installed.
                    Source remains at \(coordinator.sourceDirectoryURL.path). Edit it and build again when ready.
                    """)
            } catch is CancellationError {
                self?.finishOperation(message: "Source build cancelled. The retained checkout is available for retry.")
            } catch {
                self?.finishOperation(error: error)
            }
        }
    }

    @objc private func openEquicordSource() {
        guard !isShuttingDown, coordinator.hasRetainedSource else { return }
        guard NSWorkspace.shared.open(coordinator.sourceDirectoryURL) else {
            statusLabel.stringValue = "Could not open the retained Equicord source folder."
            return
        }
    }

    @objc private func restoreDiscord() {
        guard !isShuttingDown, let selectedTarget else { return }
        let cleanupOnly = DiscordAppPatcher.state(for: selectedTarget) == .restoredCleanupRequired
        guard confirmRestore(cleanupOnly: cleanupOnly) else { return }
        isBusy = true
        updateControls()
        statusLabel.stringValue = cleanupOnly ? "Finishing Equicord cleanup…" : "Restoring the saved Discord archive…"

        let coordinator = self.coordinator
        activeTask = Task { [weak self, coordinator] in
            do {
                try await coordinator.uninstall(target: selectedTarget)
                self?.finishOperation(message: cleanupOnly
                    ? "Equicord cleanup completed."
                    : "Discord restored. The saved Equicord payload was removed.")
            } catch {
                self?.finishOperation(error: error)
            }
        }
    }

    @objc private func cancelDownload() {
        activeTask?.cancel()
        coordinator.cancelActiveOperation()
        statusLabel.stringValue = "Cancelling the current operation…"
    }

    private func finishOperation(message: String) {
        isBusy = false
        activeTask = nil
        refreshState()
        statusLabel.stringValue = message
    }

    private func finishOperation(error: Error) {
        isBusy = false
        activeTask = nil
        refreshState()
        statusLabel.stringValue = error.localizedDescription
    }

    private func refreshState() {
        if let selectedTarget {
            targetLabel.stringValue = """
                Selected: \(selectedTarget.displayName)
                \(selectedTarget.applicationURL.path)
                """
            restoreButton.title = selectedTarget.channel == DiscordInstallTarget.Channel.custom
                ? "Restore App"
                : "Restore Discord"
            sourceBuildButton.title = coordinator.hasRetainedSource
                ? "Rebuild Dev Version from Source"
                : "Install Dev Version from Source"
            switch DiscordAppPatcher.state(for: selectedTarget) {
            case .ready:
                statusLabel.stringValue = "Ready. The prebuilt release is the default; a source dev build is optional."
                installButton.title = "Install Equicord"
                installButton.isEnabled = !isBusy
                sourceBuildButton.isEnabled = !isBusy
                restoreButton.isEnabled = false
            case .installed:
                statusLabel.stringValue = "Equicord is installed. Update the release or " +
                    "rebuild dev mode from retained source."
                installButton.title = "Update Equicord"
                installButton.isEnabled = !isBusy
                sourceBuildButton.isEnabled = !isBusy
                restoreButton.isEnabled = !isBusy
            case .backupNameRepairRequired:
                statusLabel.stringValue = "Repair the selected app's original archive path so Equicord can load."
                installButton.title = "Repair Equicord"
                installButton.isEnabled = !isBusy
                sourceBuildButton.isEnabled = false
                restoreButton.isEnabled = !isBusy

            case .restoredCleanupRequired:
                statusLabel.stringValue = "Discord is restored. Retry to remove Equicord's remaining backup files."
                installButton.isEnabled = false
                sourceBuildButton.isEnabled = false
                restoreButton.title = "Finish Cleanup"
                restoreButton.isEnabled = !isBusy

            case .repairRequired:
                statusLabel.stringValue = "Install state is incomplete. Inspect saved files; no action is available."
                installButton.isEnabled = false
                sourceBuildButton.isEnabled = false
                restoreButton.isEnabled = false
            case .anotherModificationDetected:
                statusLabel.stringValue = "Another app mod or backup is present. Restore the selected app first."
                installButton.isEnabled = false
                sourceBuildButton.isEnabled = false
                restoreButton.isEnabled = false
            }
        } else {
            targetLabel.stringValue = "No Discord-compatible app selected."
            statusLabel.stringValue = "Select an installed Discord app or choose another app bundle."
            installButton.isEnabled = false
            sourceBuildButton.isEnabled = false
            restoreButton.isEnabled = false
        }
        updateControls()
    }

    private func updateControls() {
        let canOperate = !isBusy && !isShuttingDown
        appPicker.isEnabled = canOperate
        openSourceButton.isEnabled = coordinator.hasRetainedSource && canOperate
        if !canOperate {
            installButton.isEnabled = false
            sourceBuildButton.isEnabled = false
            restoreButton.isEnabled = false
        }
        cancelButton.isHidden = !isBusy
        cancelButton.isEnabled = isBusy && !isShuttingDown
    }

    private func confirmInstall() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = selectedTarget?.channel == DiscordInstallTarget.Channel.custom
            ? "Install Equicord in this app?"
            : "Install Equicord into Discord?"
        let customWarning = selectedTarget?.channel == DiscordInstallTarget.Channel.custom
            ? "This selected custom app is not an official Discord channel and may be incompatible.\n"
            : ""
        alert.informativeText = """
            \(customWarning)This downloads and runs Equicord with the selected app's permissions.
            It replaces app.asar after saving a backup.
            It may invalidate Discord's signature, be overwritten by updates, violate its terms, or affect your account.
            Discord must be fully quit. Equicord is not affiliated with Discord or Sidekick.
            Use normal Quit to cancel; Force Quit may require manual archive recovery.
            Equicord is GPL-3.0-or-later. Review https://github.com/Equicord/Equicord/blob/main/LICENSE before installing.
            Sidekick does not bundle Equicord and does not verify an upstream signature or digest.
            """
        alert.addButton(withTitle: "Install Equicord")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmSourceBuild() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = selectedTarget?.channel == DiscordInstallTarget.Channel.custom
            ? "Install Equicord Dev in this app?"
            : "Install Equicord Dev Version from Source?"
        let customWarning = selectedTarget?.channel == DiscordInstallTarget.Channel.custom
            ? "This selected custom app is not an official Discord channel and may be incompatible.\n"
            : ""
        alert.informativeText = """
            \(customWarning)Sidekick shallow-clones Equicord main and installs locked pnpm dependencies.
            Dependency installs reuse cached packages where possible.
            `pnpm build --dev` includes dev-target plugins that run inside Discord.
            Requires Git, Node.js 22 or newer, and pnpm 12.8.1.
            The dev build defaults UserpluginInstaller on for first launch.
            Existing preferences and explicit source opt-outs are respected.
            It installs unmoderated userplugins that run with Discord's permissions.
            Only install them from developers you trust.
            Source, dependencies, and the built archive remain in Application Support for future edits.
            Build scripts run unsandboxed with your permissions; review the source and lockfile first.
            Use normal Quit to cancel; Force Quit may leave Git or pnpm processes running.
            Equicord is GPL-3.0-or-later. Client mods may violate Discord's terms or affect your account.
            """
        alert.addButton(withTitle: "Install Dev Version from Source")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmBackupNameRepair() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Repair the Equicord install?"
        alert.informativeText = """
            Equicord loads Discord from `Contents/Resources/_app.asar/package.json`.
            Sidekick copies the saved original archive to `_app.asar` and keeps the old backup until restore.
            Quit Discord completely before repairing.
            """
        alert.addButton(withTitle: "Repair Equicord")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmRestore(cleanupOnly: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if cleanupOnly {
            alert.messageText = "Finish Equicord cleanup?"
            alert.informativeText = """
                Discord's original archive is already restored.
                Quit Discord completely; Sidekick will remove only the remaining Equicord files.
                """
            alert.addButton(withTitle: "Finish Cleanup")
        } else {
            alert.messageText = "Restore the original Discord app.asar?"
            alert.informativeText = """
                Discord must be fully quit.
                Sidekick will replace its loader with the saved original archive.
                """
            alert.addButton(withTitle: "Restore Discord")
        }
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
