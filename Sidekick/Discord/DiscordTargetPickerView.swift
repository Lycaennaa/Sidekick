import AppKit
import UniformTypeIdentifiers

@MainActor
final class DiscordTargetPickerView: NSView {
    private let popup = NSPopUpButton()
    private var targets: [DiscordInstallTarget] = []
    private let discoverTargets: () -> [DiscordInstallTarget]
    private var manuallySelectedTargets: [URL: DiscordInstallTarget] = [:]

    private(set) var selectedTarget: DiscordInstallTarget?
    private var requiresExplicitSelection = false
    var onSelectionChanged: (() -> Void)?
    var onError: ((Error) -> Void)?

    var isEnabled: Bool {
        get { popup.isEnabled }
        set { popup.isEnabled = newValue }
    }

    override init(frame frameRect: NSRect) {
        discoverTargets = { DiscordInstallTarget.discover() }
        super.init(frame: frameRect)
        configure()
    }

    init(discoverTargets: @escaping () -> [DiscordInstallTarget]) {
        self.discoverTargets = discoverTargets
        super.init(frame: .zero)
        configure()
    }

    private func configure() {
        targets = discoverTargets()
        selectedTarget = targets.first
        popup.target = self
        popup.action = #selector(selectionChanged)
        popup.translatesAutoresizingMaskIntoConstraints = false
        addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor),
            popup.topAnchor.constraint(equalTo: topAnchor),
            popup.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        refreshMenu()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func refresh() {
        let previousTarget = selectedTarget
        let selectedURL = previousTarget?.applicationURL
        let previouslySelectedManually = previousTarget.map { target in
            manuallySelectedTargets[target.applicationURL].map { $0 == target } ?? false
        } ?? false
        manuallySelectedTargets = manuallySelectedTargets.compactMapValues { target in
            guard let resolvedTarget = try? DiscordInstallTarget.resolve(target.applicationURL),
                  resolvedTarget == target else {
                return nil
            }
            return resolvedTarget
        }
        let retainedManualTargets = Array(manuallySelectedTargets.values)
        var seen = Set<URL>()
        targets = (discoverTargets() + retainedManualTargets).filter { seen.insert($0.applicationURL).inserted }
        if previouslySelectedManually {
            selectedTarget = selectedURL.flatMap { manuallySelectedTargets[$0] }
            requiresExplicitSelection = selectedTarget == nil
        } else if requiresExplicitSelection {
            selectedTarget = nil
        } else {
            selectedTarget = selectedURL.flatMap { url in
                targets.first { $0.applicationURL == url }
            } ?? targets.first
        }
        refreshMenu()
        onSelectionChanged?()
    }

    @objc private func selectionChanged() {
        guard popup.isEnabled, let item = popup.selectedItem else { return }
        if item.tag == -1 {
            chooseOtherApplication()
            return
        }
        guard targets.indices.contains(item.tag) else { return }
        selectedTarget = targets[item.tag]
        requiresExplicitSelection = false
        onSelectionChanged?()
    }

    private func refreshMenu() {
        popup.removeAllItems()
        if targets.isEmpty {
            popup.addItem(withTitle: "No supported installs found")
            popup.lastItem?.tag = -2
            popup.lastItem?.isEnabled = false
        } else {
            for (index, target) in targets.enumerated() {
                let location = target.applicationURL.deletingLastPathComponent().path
                popup.addItem(withTitle: "\(target.displayName) — \(location)")
                popup.lastItem?.tag = index
                popup.lastItem?.toolTip = target.applicationURL.path
            }
        }
        popup.addItem(withTitle: "Choose Other…")
        popup.lastItem?.tag = -1

        if let selectedTarget,
           let index = targets.firstIndex(where: { $0.applicationURL == selectedTarget.applicationURL }) {
            popup.selectItem(at: index)
        } else if targets.isEmpty {
            popup.selectItem(at: 0)
        } else if requiresExplicitSelection {
            popup.selectItem(at: targets.count)
        }
    }

    private func chooseOtherApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Discord-compatible App"
        panel.message = "Select an app bundle containing Contents/Resources/app.asar."
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            refreshMenu()
            return
        }
        do {
            try selectManuallyChosenApplication(at: url)
        } catch {
            refreshMenu()
            onError?(error)
        }
    }

    func selectManuallyChosenApplication(at url: URL) throws {
        let target = try DiscordInstallTarget.resolve(url)
        if let existing = targets.firstIndex(where: { $0.applicationURL == target.applicationURL }) {
            targets[existing] = target
        } else {
            targets.append(target)
        }
        manuallySelectedTargets[target.applicationURL] = target
        selectedTarget = target
        requiresExplicitSelection = false
        refreshMenu()
        onSelectionChanged?()
    }

}
