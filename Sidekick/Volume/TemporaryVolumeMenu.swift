import AppKit
import CoreAudio

@MainActor
final class TemporaryVolumeMenu: NSObject, NSMenuDelegate {
    static let muteOptions: [(title: String, interval: TimeInterval)] = [
        ("5 Minutes", 5 * 60),
        ("15 Minutes", 15 * 60),
        ("30 Minutes", 30 * 60),
        ("1 Hour", 60 * 60),
        ("3 Hours", 3 * 60 * 60),
        ("6 Hours", 6 * 60 * 60),
        ("9 Hours", 9 * 60 * 60)
    ]

    let menu = NSMenu()

    private final class Selection: NSObject {
        let deviceID: AudioDeviceID
        let interval: TimeInterval

        init(deviceID: AudioDeviceID, interval: TimeInterval) {
            self.deviceID = deviceID
            self.interval = interval
        }
    }

    private final class DialogSelection: NSObject {
        let deviceID: AudioDeviceID

        init(deviceID: AudioDeviceID) {
            self.deviceID = deviceID
        }
    }

    private let devices: () -> [AudioOutputDevice]
    private let isActive: (AudioDeviceID) -> Bool
    private let isPending: (AudioDeviceID) -> Bool
    private let onMute: (AudioDeviceID, TimeInterval) -> Void
    private let onSchedule: (AudioDeviceID, TimeInterval, TimeInterval) -> Void
    private let onRestore: (AudioDeviceID) -> Void

    init(
        devices: @escaping () -> [AudioOutputDevice],
        isActive: @escaping (AudioDeviceID) -> Bool,
        isPending: @escaping (AudioDeviceID) -> Bool,
        onMute: @escaping (AudioDeviceID, TimeInterval) -> Void,
        onSchedule: @escaping (AudioDeviceID, TimeInterval, TimeInterval) -> Void,
        onRestore: @escaping (AudioDeviceID) -> Void
    ) {
        self.devices = devices
        self.isActive = isActive
        self.isPending = isPending
        self.onMute = onMute
        self.onSchedule = onSchedule
        self.onRestore = onRestore
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        refresh()
    }

    func refresh() {
        menu.removeAllItems()
        let outputDevices = devices()
        guard !outputDevices.isEmpty else {
            let item = NSMenuItem(title: "No Output Devices", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        for device in outputDevices {
            let deviceMenu = NSMenu()
            deviceMenu.autoenablesItems = false
            addMuteOptions(for: device, to: deviceMenu, canSchedule: !isActive(device.id))
            if isActive(device.id) {
                deviceMenu.addItem(.separator())
                let restoreItem = NSMenuItem(
                    title: isPending(device.id) ? "Cancel Scheduled Mute" : "Restore Volume Now",
                    action: #selector(restore(_:)),
                    keyEquivalent: ""
                )
                restoreItem.target = self
                restoreItem.representedObject = device.id
                deviceMenu.addItem(restoreItem)
            }

            let title = device.isDefault ? "\(device.name) (Default)" : device.name
            let deviceItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            deviceItem.submenu = deviceMenu
            menu.addItem(deviceItem)
        }
    }

    @objc private func mute(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? Selection else { return }
        onMute(selection.deviceID, selection.interval)
    }

    @objc private func showDurationDialog(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? DialogSelection else { return }
        menu.cancelTracking()

        let startField = NSTextField(string: "0")
        startField.placeholderString = "e.g. 15m"
        startField.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
        let durationField = NSTextField(string: "")
        durationField.placeholderString = "e.g. 1h 30m"
        durationField.frame = NSRect(x: 0, y: 0, width: 180, height: 24)
        startField.nextKeyView = durationField

        let fields = NSStackView(views: [
            durationRow(title: "Starts in", field: startField),
            durationRow(title: "Mute for", field: durationField)
        ])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 280, height: 56)

        let alert = NSAlert()
        alert.messageText = "Custom Mute"
        alert.informativeText = "Enter durations such as 15m or 1h 30m. Maximum 7 days."
        alert.accessoryView = fields
        alert.addButton(withTitle: "Mute")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = startField
        prepareAlert(alert)
        alert.window.makeFirstResponder(startField)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let startText = startField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let startDelay: TimeInterval
        if startText.isEmpty || startText == "0" {
            startDelay = 0
        } else if let interval = TemporaryVolumeDuration.interval(from: startText) {
            startDelay = interval
        } else {
            showInvalidDurationAlert()
            return
        }
        guard let duration = TemporaryVolumeDuration.interval(from: durationField.stringValue) else {
            showInvalidDurationAlert()
            return
        }

        if startDelay > 0 {
            onSchedule(selection.deviceID, startDelay, duration)
        } else {
            onMute(selection.deviceID, duration)
        }
    }

    @objc private func restore(_ sender: NSMenuItem) {
        guard let deviceID = sender.representedObject as? AudioDeviceID else { return }
        onRestore(deviceID)
    }

    private func addMuteOptions(
        for device: AudioOutputDevice,
        to menu: NSMenu,
        canSchedule: Bool
    ) {
        guard device.supportsTemporaryMute else {
            let item = NSMenuItem(title: "Mute Control Unavailable", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let muteMenu = NSMenu()
        muteMenu.autoenablesItems = false
        for option in Self.muteOptions {
            let item = NSMenuItem(title: option.title, action: #selector(mute(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = Selection(deviceID: device.id, interval: option.interval)
            muteMenu.addItem(item)
        }
        muteMenu.addItem(.separator())
        addDialogItem(title: "Custom…", device: device, isEnabled: canSchedule, to: muteMenu)

        let muteItem = NSMenuItem(title: "Mute", action: nil, keyEquivalent: "")
        muteItem.submenu = muteMenu
        menu.addItem(muteItem)
    }

    private func addDialogItem(
        title: String,
        device: AudioOutputDevice,
        isEnabled: Bool,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(title: title, action: #selector(showDurationDialog(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = isEnabled
        item.representedObject = DialogSelection(deviceID: device.id)
        menu.addItem(item)
    }

    private func durationRow(title: String, field: NSTextField) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.setContentHuggingPriority(.required, for: .horizontal)
        field.isEditable = true
        field.isSelectable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: 180),
            field.heightAnchor.constraint(equalToConstant: 24)
        ])
        let row = NSStackView(views: [label, field])
        row.spacing = 8
        return row
    }

    private func showInvalidDurationAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Invalid Duration"
        alert.informativeText = "Enter valid Starts in and Mute for durations, up to 7 days."
        alert.addButton(withTitle: "OK")
        prepareAlert(alert)
        alert.runModal()
    }

    private func prepareAlert(_ alert: NSAlert) {
        alert.window.level = .statusBar
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        NSApp.activate(ignoringOtherApps: true)
    }
}
