import AppKit

@MainActor
final class MacArtifactCleanupSettingsView: NSView {
    let store: MacArtifactCleanupStore
    let coordinator: MacArtifactCleanupCoordinator
    private let defaultModePopup = NSPopUpButton()
    private let rootRows = NSStackView()
    private let historyRows = NSStackView()
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var activeFolderEnrollmentID: UUID?
    var activePreviewRequestID: UUID?
    var activeCleanupPrompt: MacArtifactCleanupPromptPanel?

    init(store: MacArtifactCleanupStore, coordinator: MacArtifactCleanupCoordinator) {
        self.store = store
        self.coordinator = coordinator
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildView()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refresh() {
        configureModePopup(defaultModePopup, selectedMode: store.configuration.defaultMode)
        rebuildRootRows()
        rebuildHistoryRows()
        statusLabel.stringValue = store.configuration.roots.isEmpty
            ? "No folders or drives enrolled."
            : "Monitoring runs while Sidekick is open and waits 30 seconds without observed file changes."
    }

    private func buildView() {
        let title = NSTextField(labelWithString: "Mac cleanup")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let explanation = NSTextField(
            wrappingLabelWithString:
                "Recursively remove `.DS_Store`, verified AppleDouble sidecars (`._*`), and exact " +
                "`.AppleDouble` / `__MACOSX` directories. ZIP files are not rewritten. Package folders and " +
                "symlinks are skipped; traversal stays on the selected volume. Folders on local or external " +
                "disks and FUSE volumes (including network-backed FUSE) are supported; mounted disk images " +
                "and other virtual or network volumes are not."
        )
        explanation.textColor = .secondaryLabelColor
        explanation.font = .systemFont(ofSize: 12)

        let safety = makeSafetyLabel()

        let modeLabel = NSTextField(labelWithString: "Automatic action")
        let modeRow = NSStackView(views: [modeLabel, defaultModePopup])
        modeRow.orientation = .horizontal
        modeRow.alignment = .centerY
        modeRow.spacing = 10
        defaultModePopup.target = self
        defaultModePopup.action = #selector(defaultModeChanged(_:))

        let addFolderButton = NSButton(title: "Add Folder…", target: self, action: #selector(addFolder))
        addFolderButton.bezelStyle = .rounded
        let rootsTitle = NSTextField(labelWithString: "Watched locations")
        rootsTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        rootRows.orientation = .vertical
        rootRows.alignment = .leading
        rootRows.spacing = 10

        let historyTitle = NSTextField(labelWithString: "Recent cleanup history")
        historyTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        historyRows.orientation = .vertical
        historyRows.alignment = .leading
        historyRows.spacing = 6
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)

        let stack = NSStackView(views: [
            title,
            explanation,
            safety,
            modeRow,
            addFolderButton,
            rootsTitle,
            rootRows,
            historyTitle,
            historyRows,
            statusLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            safety.widthAnchor.constraint(equalTo: stack.widthAnchor),
            rootRows.widthAnchor.constraint(equalTo: stack.widthAnchor),
            historyRows.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    private func makeSafetyLabel() -> NSTextField {
        let safety = NSTextField(
            wrappingLabelWithString:
                "A 30-second period without observed size or modification-time changes is only a stability " +
                "heuristic—not copy verification. Permanent deletion cannot be undone; choose Trash or Preview " +
                "for safer behavior."
        )
        safety.textColor = .secondaryLabelColor
        safety.font = .systemFont(ofSize: 12)
        return safety
    }

    private func rebuildRootRows() {
        removeArrangedSubviews(from: rootRows)
        for root in store.configuration.roots {
            let title = NSTextField(labelWithString: root.name)
            title.font = .systemFont(ofSize: 13, weight: .medium)
            let path = NSTextField(wrappingLabelWithString: root.path)
            path.textColor = .secondaryLabelColor
            path.font = .systemFont(ofSize: 11)
            path.toolTip = root.path
            let location = NSStackView(views: [title, path])
            location.orientation = .vertical
            location.alignment = .leading
            location.spacing = 3

            let modePopup = NSPopUpButton()
            modePopup.identifier = NSUserInterfaceItemIdentifier(root.id.uuidString)
            configureModePopup(modePopup, selectedMode: root.modeOverride, showsDefaultOption: true)
            modePopup.target = self
            modePopup.action = #selector(rootModeChanged(_:))

            let previewButton = NSButton(title: "Preview…", target: self, action: #selector(previewCleanup(_:)))
            previewButton.identifier = NSUserInterfaceItemIdentifier(root.id.uuidString)
            previewButton.bezelStyle = .rounded
            let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeRoot(_:)))
            removeButton.identifier = NSUserInterfaceItemIdentifier(root.id.uuidString)
            removeButton.bezelStyle = .rounded

            let row = NSStackView(views: [location, modePopup, previewButton, removeButton])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            location.setContentHuggingPriority(.defaultLow, for: .horizontal)
            location.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            modePopup.setContentHuggingPriority(.required, for: .horizontal)
            previewButton.setContentHuggingPriority(.required, for: .horizontal)
            removeButton.setContentHuggingPriority(.required, for: .horizontal)
            rootRows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rootRows.widthAnchor).isActive = true
        }
    }

    private func rebuildHistoryRows() {
        removeArrangedSubviews(from: historyRows)
        for entry in store.history.prefix(8) {
            let date = DateFormatter.localizedString(from: entry.date, dateStyle: .short, timeStyle: .short)
            let title = NSTextField(labelWithString:
                "\(date) — \(entry.removedCount) removed, \(entry.skippedCount) skipped"
            )
            title.toolTip = ([entry.rootPath] + entry.details).joined(separator: "\n")
            historyRows.addArrangedSubview(title)
        }
        if store.history.isEmpty {
            historyRows.addArrangedSubview(NSTextField(wrappingLabelWithString: "No cleanup runs yet."))
        }
    }

    private func configureModePopup(
        _ popup: NSPopUpButton,
        selectedMode: MacArtifactRemovalMode?,
        showsDefaultOption: Bool = false
    ) {
        popup.removeAllItems()
        if showsDefaultOption {
            popup.addItem(withTitle: "Use default")
            popup.lastItem?.representedObject = "default"
        }
        let modes: [(String, MacArtifactRemovalMode)] = [
            ("Preview only", .previewOnly),
            ("Move to Trash", .moveToTrash),
            ("Delete permanently", .deletePermanently)
        ]
        for (title, mode) in modes {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = mode.rawValue
        }
        let selected = selectedMode?.rawValue ?? "default"
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == selected }) {
            popup.select(item)
        }
    }

    private func removeArrangedSubviews(from stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    @objc private func defaultModeChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let mode = MacArtifactRemovalMode(rawValue: rawValue) else {
            return
        }
        store.setDefaultMode(mode)
        refresh()
    }

    @objc private func rootModeChanged(_ sender: NSPopUpButton) {
        guard let idString = sender.identifier?.rawValue,
              let id = UUID(uuidString: idString),
              let rawValue = sender.selectedItem?.representedObject as? String else {
            return
        }
        store.setModeOverride(
            rawValue == "default" ? nil : MacArtifactRemovalMode(rawValue: rawValue),
            forRootID: id
        )
        refresh()
    }

    @objc private func addFolder() {
        guard activeFolderEnrollmentID == nil, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch Folder"
        panel.message = "Select a folder to scan and monitor while Sidekick is open."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                await self?.enrollFolder(url)
            }
        }
    }

    func enrollFolder(_ url: URL) async {
        guard activeFolderEnrollmentID == nil else { return }
        let enrollmentID = UUID()
        activeFolderEnrollmentID = enrollmentID
        statusLabel.stringValue = "Checking selected location…"
        let added = await store.addFolder(url)
        guard activeFolderEnrollmentID == enrollmentID else { return }
        activeFolderEnrollmentID = nil
        refresh()
        if !added {
            statusLabel.stringValue = "That folder is already enrolled or is on an unsupported volume."
        }
    }

    @objc private func removeRoot(_ sender: NSButton) {
        guard let idString = sender.identifier?.rawValue, let id = UUID(uuidString: idString) else { return }
        store.removeRoot(id: id)
        refresh()
    }

}
