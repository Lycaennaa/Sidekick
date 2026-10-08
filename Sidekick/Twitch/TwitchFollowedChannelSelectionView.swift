import AppKit

@MainActor
final class TwitchFollowedChannelSelectionView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private static let channelColumnIdentifier = NSUserInterfaceItemIdentifier("TwitchFollowedChannel")
    private static let channelCellIdentifier = NSUserInterfaceItemIdentifier("TwitchFollowedChannelCell")
    private let settings: AppSettings
    private let controller: TwitchNotificationController
    private let channelSearchField = NSSearchField()
    private var visibleChannels: [TwitchFollowedChannel] = []
    private let channelModePopup = NSPopUpButton()
    private let channelTableView = NSTableView()
    private let channelScrollView = NSScrollView()
    private let channelListStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let channelSelectionControls = NSStackView()
    private let keepSelectionsBetweenModesCheckbox = NSButton(
        checkboxWithTitle: "Keep checked between modes",
        target: nil,
        action: nil
    )

    init(settings: AppSettings, controller: TwitchNotificationController) {
        self.settings = settings
        self.controller = controller
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        channelListStatusLabel.textColor = .secondaryLabelColor
        channelListStatusLabel.font = .systemFont(ofSize: 12)
        buildView()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func refresh() {
        let mode = settings.twitchNotificationChannelMode
        let modes = TwitchNotificationChannelMode.allCases
        channelModePopup.selectItem(at: modes.firstIndex(of: mode) ?? 0)
        let pickerBackgroundColor = AppTheme.resolvedAppearance == .amoledBlack
            ? NSColor.black
            : NSColor.controlBackgroundColor
        channelTableView.backgroundColor = pickerBackgroundColor
        channelScrollView.drawsBackground = true
        channelScrollView.backgroundColor = pickerBackgroundColor
        keepSelectionsBetweenModesCheckbox.state = settings.twitchKeepChannelSelectionsBetweenModes ? .on : .off
        channelSelectionControls.isHidden = mode == .all
        visibleChannels = TwitchFollowedChannelSearch.filter(
            controller.followedChannels,
            query: channelSearchField.stringValue
        )
        channelTableView.reloadData()
        channelScrollView.isHidden = controller.followedChannels.isEmpty || mode == .all
        channelListStatusLabel.stringValue = channelListStatusMessage
        channelListStatusLabel.isHidden = channelListStatusMessage.isEmpty || mode == .all
    }

    private func buildView() {
        let modeRow = makeChannelModeRow()
        let controls = makeChannelSelectionControls()
        let stack = NSStackView(views: [modeRow, controls, channelListStatusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            channelListStatusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func changeChannelMode() {
        let modes = TwitchNotificationChannelMode.allCases
        guard modes.indices.contains(channelModePopup.indexOfSelectedItem) else { return }
        settings.twitchNotificationChannelMode = modes[channelModePopup.indexOfSelectedItem]
        refresh()
    }

    @objc private func toggleSelectedChannel(_ sender: NSButton) {
        let mode = settings.twitchNotificationChannelMode
        guard mode != .all, visibleChannels.indices.contains(sender.tag) else { return }
        var selectedIDs = settings.twitchSelectedChannelIDs(for: mode)
        let channelID = visibleChannels[sender.tag].id
        if sender.state == .on {
            selectedIDs.insert(channelID)
        } else {
            selectedIDs.remove(channelID)
        }
        settings.setTwitchSelectedChannelIDs(selectedIDs, for: mode)
        refresh()
    }

    @objc private func toggleKeepSelectionsBetweenModes() {
        settings.setTwitchKeepChannelSelectionsBetweenModes(
            keepSelectionsBetweenModesCheckbox.state == .on,
            using: settings.twitchNotificationChannelMode
        )
        refresh()
    }

    private var channelListStatusMessage: String {
        if controller.followedChannelsLoadFailed {
            return controller.hasLoadedFollowedChannels
                ? "Could not refresh followed channels; showing the last list."
                : "Could not load followed channels; retrying."
        }
        if !controller.hasLoadedFollowedChannels {
            return "Enable Twitch notifications and save a token to load followed channels."
        }
        if controller.followedChannels.isEmpty {
            return "Your Twitch account follows no channels."
        }
        return visibleChannels.isEmpty ? "No followed channels match this search." : ""
    }

    private func makeChannelModeRow() -> NSStackView {
        channelModePopup.addItems(withTitles: TwitchNotificationChannelMode.allCases.map(\.title))
        channelModePopup.target = self
        channelModePopup.action = #selector(changeChannelMode)
        let label = NSTextField(labelWithString: "Notify for")
        let row = NSStackView(views: [label, channelModePopup])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func makeChannelSelectionControls() -> NSStackView {
        let helpLabel = NSTextField(
            wrappingLabelWithString:
                "Checked lists are separate by default. Enable “Keep checked between modes” to share them. " +
                "Only checked mode with none checked sends no notifications."
        )
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.font = .systemFont(ofSize: 12)
        channelSearchField.placeholderString = "Search followed channels"
        channelSearchField.target = self
        channelSearchField.action = #selector(searchFieldChanged)
        channelSearchField.sendsSearchStringImmediately = true
        let channelPicker = makeChannelPicker()
        keepSelectionsBetweenModesCheckbox.target = self
        keepSelectionsBetweenModesCheckbox.action = #selector(toggleKeepSelectionsBetweenModes)
        channelSelectionControls.orientation = .vertical
        channelSelectionControls.alignment = .leading
        channelSelectionControls.spacing = 8
        channelSelectionControls.addArrangedSubview(helpLabel)
        channelSelectionControls.addArrangedSubview(keepSelectionsBetweenModesCheckbox)
        channelSelectionControls.addArrangedSubview(channelSearchField)
        channelSelectionControls.addArrangedSubview(channelPicker)
        NSLayoutConstraint.activate([
            helpLabel.widthAnchor.constraint(equalTo: channelSelectionControls.widthAnchor),
            channelSearchField.widthAnchor.constraint(equalTo: channelSelectionControls.widthAnchor),
            channelPicker.widthAnchor.constraint(equalTo: channelSelectionControls.widthAnchor)
        ])
        return channelSelectionControls
    }

    private func makeChannelPicker() -> NSScrollView {
        let column = NSTableColumn(identifier: Self.channelColumnIdentifier)
        column.width = 420
        channelTableView.addTableColumn(column)
        channelTableView.headerView = nil
        channelTableView.rowHeight = 24
        channelTableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        channelTableView.dataSource = self
        channelTableView.delegate = self
        channelTableView.frame = NSRect(x: 0, y: 0, width: 420, height: 0)
        channelTableView.autoresizingMask = [.width]
        channelScrollView.documentView = channelTableView
        channelScrollView.hasVerticalScroller = true
        channelScrollView.borderType = .bezelBorder
        channelScrollView.translatesAutoresizingMaskIntoConstraints = false
        channelScrollView.heightAnchor.constraint(equalToConstant: 140).isActive = true
        return channelScrollView
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleChannels.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleChannels.indices.contains(row) else { return nil }
        let channel = visibleChannels[row]
        let button = tableView.makeView(withIdentifier: Self.channelCellIdentifier, owner: self) as? NSButton
            ?? NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleSelectedChannel(_:)))
        button.identifier = Self.channelCellIdentifier
        button.title = "\(channel.name) (@\(channel.login))"
        button.tag = row
        button.state = settings.twitchSelectedChannelIDs(for: settings.twitchNotificationChannelMode)
            .contains(channel.id) ? .on : .off
        button.target = self
        button.action = #selector(toggleSelectedChannel(_:))
        return button
    }

    @objc private func searchFieldChanged() {
        refresh()
    }
}
