import AppKit

enum ToolsSettingsPage: Int, CaseIterable {
    case clipboard
    case screenshots
    case twitch
    case audio
    case outputVolume
    case appearance

    var title: String {
        switch self {
        case .clipboard: "Clipboard"
        case .screenshots: "Screenshots"
        case .twitch: "Twitch"
        case .audio: "Audio"
        case .outputVolume: "Output Volume"
        case .appearance: "Appearance"
        }
    }

    var symbolName: String {
        switch self {
        case .clipboard: "doc.on.clipboard"
        case .screenshots: "viewfinder"
        case .twitch: "bell.badge"
        case .audio: "waveform"
        case .outputVolume: "speaker.wave.2"
        case .appearance: "paintpalette"
        }
    }
}

@MainActor
final class ToolsSidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private static let columnIdentifier = NSUserInterfaceItemIdentifier("SettingsPage")
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("SettingsPageCell")

    var onSelection: ((ToolsSettingsPage) -> Void)?

    private let tableView = NSTableView()

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false

        tableView.style = .sourceList
        tableView.headerView = nil
        tableView.rowHeight = 36
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = false
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.frame = NSRect(
            x: 0,
            y: 0,
            width: 220,
            height: CGFloat(ToolsSettingsPage.allCases.count) * 40
        )
        tableView.autoresizingMask = [.width]
        tableView.addTableColumn(NSTableColumn(identifier: Self.columnIdentifier))
        scrollView.documentView = tableView
        view = scrollView
        tableView.selectRowIndexes(IndexSet(integer: ToolsSettingsPage.clipboard.rawValue), byExtendingSelection: false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applyAppearance()
    }

    func applyAppearance() {
        guard isViewLoaded else { return }
        let activeAppearance = AppTheme.resolvedAppearance
        let usesCustomBackground = activeAppearance == .dark || activeAppearance == .amoledBlack
        let surfaceColor = usesCustomBackground ? AppTheme.sidebarSurface : NSColor.clear
        view.wantsLayer = usesCustomBackground
        view.layer?.backgroundColor = usesCustomBackground ? surfaceColor.cgColor : nil
        tableView.backgroundColor = surfaceColor
        if let scrollView = view as? NSScrollView {
            scrollView.drawsBackground = usesCustomBackground
            scrollView.backgroundColor = surfaceColor
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        ToolsSettingsPage.allCases.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let page = ToolsSettingsPage(rawValue: row) else { return nil }
        let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? NSTableCellView
            ?? makeCell()
        cell.textField?.stringValue = page.title
        cell.imageView?.image = NSImage(
            systemSymbolName: page.symbolName,
            accessibilityDescription: page.title
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let page = ToolsSettingsPage(rawValue: tableView.selectedRow) else { return }
        onSelection?(page)
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = Self.cellIdentifier

        let iconView = NSImageView()
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: "")
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(iconView)
        cell.addSubview(titleField)
        cell.imageView = iconView
        cell.textField = titleField

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            titleField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            titleField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
