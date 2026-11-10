import AppKit

extension MacArtifactCleanupSettingsView {
    @objc func previewCleanup(_ sender: NSButton) {
        guard activePreviewRequestID == nil,
              activeCleanupPrompt == nil,
              let idString = sender.identifier?.rawValue,
              let rootID = UUID(uuidString: idString) else {
            return
        }
        let requestID = UUID()
        activePreviewRequestID = requestID
        startPreview(rootID: rootID, requestID: requestID)
    }

    private func startPreview(rootID: UUID, requestID: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let scan = try await coordinator.preview(rootID: rootID)
                finishPreview(scan, rootID: rootID, requestID: requestID)
            } catch is CancellationError {
                finishCancelledPreview(requestID: requestID)
            } catch {
                finishPreviewFailure(error, requestID: requestID)
            }
        }
    }

    private func finishPreview(
        _ scan: MacArtifactScanResult,
        rootID: UUID,
        requestID: UUID
    ) {
        guard activePreviewRequestID == requestID else { return }
        activePreviewRequestID = nil
        guard !Task.isCancelled,
              store.configuration.roots.contains(where: { $0.id == rootID }) else {
            return
        }
        showPreview(scan, rootID: rootID)
    }

    private func finishCancelledPreview(requestID: UUID) {
        guard activePreviewRequestID == requestID else { return }
        activePreviewRequestID = nil
    }

    private func finishPreviewFailure(_ error: Error, requestID: UUID) {
        guard activePreviewRequestID == requestID else { return }
        activePreviewRequestID = nil
        guard !Task.isCancelled else { return }
        showMessage("Couldn’t scan folder", detail: error.localizedDescription)
    }

    private func showPreview(_ scan: MacArtifactScanResult, rootID: UUID) {
        guard !scan.matches.isEmpty else {
            let detail = scan.issues.prefix(8).map { "\($0.path): \($0.reason)" }.joined(separator: "\n")
            showMessage(
                "No cleanup candidates found",
                detail: detail.isEmpty ? "The selected root was scanned." : detail
            )
            return
        }
        let paths = scan.matches.prefix(12).map(\.url.path).joined(separator: "\n")
        let remainder = scan.matches.count > 12 ? "\n…and \(scan.matches.count - 12) more" : ""
        let detail = paths + remainder
            + "\n\nManual actions require 30 seconds without observed changes; new or active items will be skipped."
        let prompt = MacArtifactCleanupPromptPanel(
            title: "\(scan.matches.count) cleanup candidates found",
            detail: detail,
            buttons: [
                .init(title: "Move to Trash", action: { [weak self] in
                    guard let self else { return }
                    applyManualCleanup(scan.matches, rootID: rootID, mode: .moveToTrash)
                }),
                .init(title: "Delete Permanently…", action: { [weak self] in
                    guard let self else { return }
                    confirmPermanentDeletion(scan.matches, rootID: rootID)
                }),
                .init(title: "Cancel", action: { [weak self] in self?.refresh() })
            ]
        )
        presentCleanupPrompt(prompt, onClose: { [weak self] in self?.refresh() })
    }

    private func confirmPermanentDeletion(_ matches: [MacArtifactMatch], rootID: UUID) {
        let prompt = MacArtifactCleanupPromptPanel(
            title: "Permanently delete these items?",
            detail:
                "This cannot be undone. Items must remain unchanged for at least 30 seconds; " +
                "active or changed items will be skipped.",
            buttons: [
                .init(title: "Delete Permanently", action: { [weak self] in
                    guard let self else { return }
                    applyManualCleanup(matches, rootID: rootID, mode: .deletePermanently)
                }),
                .init(title: "Cancel", action: { [weak self] in self?.refresh() })
            ]
        )
        presentCleanupPrompt(prompt, onClose: { [weak self] in self?.refresh() })
    }

    private func applyManualCleanup(
        _ matches: [MacArtifactMatch],
        rootID: UUID,
        mode: MacArtifactRemovalMode
    ) {
        let result = coordinator.applyManually(matches, rootID: rootID, mode: mode)
        refresh()
        guard let result else {
            statusLabel.stringValue =
                "Cleanup could not be applied because the watched root changed " +
                "or another run is active."
            return
        }
        if result.skippedCount > 0 {
            let detail = result.details.first ?? "The candidates are not stable yet."
            statusLabel.stringValue = "\(result.skippedCount) item(s) skipped: \(detail)"
        }
    }

    private func presentCleanupPrompt(
        _ prompt: MacArtifactCleanupPromptPanel,
        onClose: (@MainActor () -> Void)? = nil
    ) {
        guard activeCleanupPrompt == nil else { return }
        activeCleanupPrompt = prompt
        prompt.onDismiss = { [weak self, weak prompt] in
            guard let self,
                  let prompt,
                  activeCleanupPrompt === prompt else {
                return
            }
            activeCleanupPrompt = nil
        }
        prompt.onClose = onClose
        prompt.show()
    }

    private func showMessage(_ title: String, detail: String) {
        let prompt = MacArtifactCleanupPromptPanel(
            title: title,
            detail: detail,
            buttons: [.init(title: "OK")]
        )
        presentCleanupPrompt(prompt)
    }

}
