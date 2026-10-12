import AppKit
import CoreAudio

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    enum ToolState {
        case active
        case paused
        case disabled
    }

    private static let clipboardPauseOptions: [(title: String, interval: TimeInterval)] = [
        ("15 Minutes", 15 * 60),
        ("1 Hour", 60 * 60)
    ]
    private let settings: AppSettings
    private let screenshotCaptureMenu: ScreenshotCaptureMenu
    private let onShowTools: () -> Void
    private let onCleanMarkdown: () -> Void
    private let onToggleTwitchNotifications: () -> Void
    private let onPause: (TimeInterval?) -> Void
    private let onResume: () -> Void
    private let onQuit: () -> Void
    private let temporaryVolumeFeature: TemporaryVolumeFeature
    private let twitchLiveItem = NSMenuItem(
        title: "Twitch Live",
        action: nil,
        keyEquivalent: ""
    )
    private let twitchLiveMenu: TwitchLiveMenu

    private let clearURLsClipboardAvailable: Bool
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private let microphoneToastMenu: MicrophoneToastMenu
    private let temporaryVolumeItem = NSMenuItem(
        title: "Mute",
        action: nil,
        keyEquivalent: ""
    )
    private let resetVolumeItem = NSMenuItem(
        title: "Reset Volume",
        action: nil,
        keyEquivalent: ""
    )
    private let twitchNotificationsItem = NSMenuItem(
        title: "Twitch Notifications",
        action: nil,
        keyEquivalent: ""
    )
    private let clipboardToastItem = NSMenuItem(title: "Clipboard Toast", action: nil, keyEquivalent: "")
    private let markdownClipboardItem = NSMenuItem(
        title: "Markdown Clipboard Cleaner",
        action: nil,
        keyEquivalent: ""
    )
    private let microphoneToastItem = NSMenuItem(
        title: "Microphone Toast",
        action: nil,
        keyEquivalent: ""
    )
    private let cleanMarkdownNowItem = NSMenuItem(
        title: "Clean Markdown Clipboard Now",
        action: nil,
        keyEquivalent: ""
    )
    private let microphoneToastOptionsItem = NSMenuItem(
        title: "Microphone Toast Options…",
        action: nil,
        keyEquivalent: ""
    )
    private let imageConversionItem = NSMenuItem(
        title: "Clipboard image converter",
        action: nil,
        keyEquivalent: ""
    )
    private let clearURLsClipboardItem = NSMenuItem(
        title: "ClearURLs Clipboard Cleaner",
        action: nil,
        keyEquivalent: ""
    )
    private let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
    private let resumeItem = NSMenuItem(title: "Resume", action: nil, keyEquivalent: "")
    private let excludedApplicationsMenu = NSMenu()
    private var pauseOptionItems: [NSMenuItem] = []
    private var durationItems: [NSMenuItem] = []

    init(
        settings: AppSettings,
        clearURLsClipboardAvailable: Bool,
        onShowTools: @escaping () -> Void,
        onCleanMarkdown: @escaping () -> Void,
        onCaptureScreenshot: @escaping (ScreenshotCaptureMode, Bool?) -> Void,
        onToggleTwitchNotifications: @escaping () -> Void,
        onPause: @escaping (TimeInterval?) -> Void,
        onResume: @escaping () -> Void,
        onHideMicrophoneToast: @escaping (TimeInterval?) -> Void,
        onShowMicrophoneToast: @escaping () -> Void,
        temporaryVolumeFeature: TemporaryVolumeFeature,
        onQuit: @escaping () -> Void
    ) {
        self.settings = settings
        self.screenshotCaptureMenu = ScreenshotCaptureMenu(
            settings: settings,
            onCaptureScreenshot: onCaptureScreenshot
        )
        self.clearURLsClipboardAvailable = clearURLsClipboardAvailable
        self.onShowTools = onShowTools
        self.onCleanMarkdown = onCleanMarkdown
        self.onToggleTwitchNotifications = onToggleTwitchNotifications
        self.onPause = onPause
        self.onResume = onResume
        self.microphoneToastMenu = MicrophoneToastMenu(
            onHide: onHideMicrophoneToast,
            onShow: onShowMicrophoneToast
        )
        self.temporaryVolumeFeature = temporaryVolumeFeature
        self.twitchLiveMenu = TwitchLiveMenu()
        self.onQuit = onQuit
        super.init()
        installMenu()
        refresh(toolState: settings.clipboardToastEnabled ? .active : .disabled)
    }

    func refresh(toolState: ToolState) {
        let enabled = toolState != .disabled
        screenshotCaptureMenu.refresh()
        clipboardToastItem.state = enabled ? .on : .off
        markdownClipboardItem.state = settings.markdownClipboardCleanerEnabled ? .on : .off
        cleanMarkdownNowItem.isEnabled = true
        imageConversionItem.state = settings.imageConversionEnabled ? .on : .off
        twitchNotificationsItem.state = settings.twitchNotificationsEnabled ? .on : .off
        clearURLsClipboardItem.state = clearURLsClipboardAvailable && settings.clearURLsClipboardEnabled ? .on : .off
        clearURLsClipboardItem.isEnabled = clearURLsClipboardAvailable
        microphoneToastItem.state = settings.microphoneToastEnabled ? .on : .off
        microphoneToastOptionsItem.isEnabled = settings.microphoneToastEnabled
        let volumeIsActive = temporaryVolumeFeature.hasActiveTimers()
        resetVolumeItem.isHidden = !volumeIsActive
        resetVolumeItem.isEnabled = volumeIsActive

        pauseItem.isEnabled = enabled
        for item in pauseOptionItems {
            item.isEnabled = enabled
        }
        resumeItem.isHidden = toolState != .paused
        resumeItem.isEnabled = toolState == .paused

        for item in durationItems {
            guard let duration = item.representedObject as? NSNumber else { continue }
            item.state = duration.doubleValue == settings.toastDuration ? .on : .off
        }
        rebuildExcludedApplicationsMenu()

        let symbolName: String
        let alpha: CGFloat
        switch toolState {
        case .active:
            symbolName = "wrench.and.screwdriver"
            alpha = 1
        case .paused:
            symbolName = "pause.circle"
            alpha = 1
        case .disabled:
            symbolName = "wrench.and.screwdriver"
            alpha = 1
        }

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: "Sidekick"
            )
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.title = "\(twitchLiveMenu.liveCount)"
            button.alphaValue = alpha
        }
    }
    func refreshTemporaryVolumeMenu() {
        temporaryVolumeFeature.refresh()
        let volumeIsActive = temporaryVolumeFeature.hasActiveTimers()
        resetVolumeItem.isHidden = !volumeIsActive
        resetVolumeItem.isEnabled = volumeIsActive
    }

    func refreshTwitchStreams(_ streams: [TwitchFollowedStream]) {
        twitchLiveMenu.refresh(streams)
        statusItem.button?.title = "\(twitchLiveMenu.liveCount)"
    }

    var microphoneToastOptionsMenu: NSMenu { microphoneToastMenu.menu }

    private func installMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addPrimaryMenuItems(to: menu)
        addPauseMenu(to: menu)
        addDurationMenu(to: menu)
        addExcludedApplicationsMenu(to: menu)
        addQuitItem(to: menu)
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === excludedApplicationsMenu else { return }
        rebuildExcludedApplicationsMenu()
    }

    @objc private func showTools() {
        statusItem.menu?.cancelTracking()
        DispatchQueue.main.async { [onShowTools] in
            onShowTools()
        }
    }

    @objc private func toggleClipboardToast() {
        settings.clipboardToastEnabled.toggle()
    }

    @objc private func toggleMarkdownClipboardCleaner() {
        settings.markdownClipboardCleanerEnabled.toggle()
    }

    @objc private func toggleMicrophoneToast() {
        settings.microphoneToastEnabled.toggle()
    }

    @objc private func toggleTwitchNotifications() {
        onToggleTwitchNotifications()
    }

    @objc private func toggleImageConversion() {
        settings.imageConversionEnabled.toggle()
    }

    @objc private func toggleClearURLsClipboard() {
        guard clearURLsClipboardAvailable else { return }
        settings.clearURLsClipboardEnabled.toggle()
    }

    @objc private func cleanMarkdown() {
        onCleanMarkdown()
    }
    @objc private func selectDuration(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? NSNumber else { return }
        settings.toastDuration = duration.doubleValue
    }

    @objc private func toggleExcludedApplication(_ sender: NSMenuItem) {
        guard let bundleIdentifier = sender.representedObject as? String else { return }
        var excluded = settings.excludedToastApplicationBundleIdentifiers
        if excluded.contains(bundleIdentifier) {
            excluded.remove(bundleIdentifier)
        } else {
            excluded.insert(bundleIdentifier)
        }
        settings.excludedToastApplicationBundleIdentifiers = excluded
    }

    @objc private func selectPause(_ sender: NSMenuItem) {
        let interval = (sender.representedObject as? NSNumber)?.doubleValue
        onPause(interval)
    }

    @objc private func resume() {
        onResume()
    }

    @objc private func resetVolume() {
        statusItem.menu?.cancelTracking()
        temporaryVolumeFeature.restoreAll()
    }

    @objc private func quit() {
        onQuit()
    }

    private static func durationTitle(_ duration: TimeInterval) -> String {
        duration.rounded() == duration
            ? "\(Int(duration)) Seconds"
            : "\(duration.formatted()) Seconds"
    }

    private func addPauseItem(title: String, interval: TimeInterval?, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(selectPause(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = interval.map(NSNumber.init(value:))
        menu.addItem(item)
        pauseOptionItems.append(item)
    }

    private func rebuildExcludedApplicationsMenu() {
        let excluded = settings.excludedToastApplicationBundleIdentifiers
        var applicationsByBundleIdentifier: [String: String] = [:]

        for application in NSWorkspace.shared.runningApplications
        where application.activationPolicy != .prohibited {
            guard let bundleIdentifier = application.bundleIdentifier else { continue }
            applicationsByBundleIdentifier[bundleIdentifier] = application.localizedName
                ?? Self.applicationName(for: bundleIdentifier)
        }

        for bundleIdentifier in excluded where applicationsByBundleIdentifier[bundleIdentifier] == nil {
            applicationsByBundleIdentifier[bundleIdentifier] = Self.applicationName(for: bundleIdentifier)
        }

        excludedApplicationsMenu.removeAllItems()
        for (bundleIdentifier, name) in applicationsByBundleIdentifier.sorted(by: {
            $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending
        }) {
            let item = NSMenuItem(
                title: name,
                action: #selector(toggleExcludedApplication(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = bundleIdentifier
            item.state = excluded.contains(bundleIdentifier) ? .on : .off
            excludedApplicationsMenu.addItem(item)
        }

        if excludedApplicationsMenu.items.isEmpty {
            let item = NSMenuItem(title: "No Running Apps", action: nil, keyEquivalent: "")
            item.isEnabled = false
            excludedApplicationsMenu.addItem(item)
        }
    }

    private static func applicationName(for bundleIdentifier: String) -> String {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return bundleIdentifier
        }
        let bundle = Bundle(url: applicationURL)
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? applicationURL.deletingPathExtension().lastPathComponent
    }
}
extension StatusMenuController {
    private func addPrimaryMenuItems(to menu: NSMenu) {
        let showToolsItem = NSMenuItem(
            title: "Show Tools…",
            action: #selector(showTools),
            keyEquivalent: ""
        )
        showToolsItem.target = self
        menu.addItem(showToolsItem)

        screenshotCaptureMenu.add(to: menu)

        clipboardToastItem.action = #selector(toggleClipboardToast)
        clipboardToastItem.target = self
        menu.addItem(clipboardToastItem)

        imageConversionItem.action = #selector(toggleImageConversion)
        imageConversionItem.target = self
        menu.addItem(imageConversionItem)

        clearURLsClipboardItem.action = #selector(toggleClearURLsClipboard)
        clearURLsClipboardItem.target = self
        menu.addItem(clearURLsClipboardItem)

        twitchNotificationsItem.action = #selector(toggleTwitchNotifications)
        twitchNotificationsItem.target = self
        menu.addItem(twitchNotificationsItem)

        markdownClipboardItem.action = #selector(toggleMarkdownClipboardCleaner)
        markdownClipboardItem.target = self
        menu.addItem(markdownClipboardItem)

        microphoneToastItem.action = #selector(toggleMicrophoneToast)
        microphoneToastItem.target = self
        menu.addItem(microphoneToastItem)

        cleanMarkdownNowItem.action = #selector(cleanMarkdown)
        cleanMarkdownNowItem.target = self
        menu.addItem(cleanMarkdownNowItem)

        microphoneToastOptionsItem.submenu = microphoneToastMenu.menu
        menu.addItem(microphoneToastOptionsItem)
        temporaryVolumeItem.submenu = temporaryVolumeFeature.menu.menu
        menu.addItem(temporaryVolumeItem)
        resetVolumeItem.action = #selector(resetVolume)
        resetVolumeItem.target = self
        resetVolumeItem.isHidden = true
        menu.addItem(resetVolumeItem)
        twitchLiveItem.submenu = twitchLiveMenu.menu
        menu.addItem(twitchLiveItem)
    }

    private func addPauseMenu(to menu: NSMenu) {
        let pauseMenu = NSMenu()
        pauseMenu.autoenablesItems = false
        for option in Self.clipboardPauseOptions {
            addPauseItem(title: option.title, interval: option.interval, to: pauseMenu)
        }
        addPauseItem(title: "Until Resumed", interval: nil, to: pauseMenu)
        resumeItem.action = #selector(resume)
        resumeItem.target = self
        pauseMenu.addItem(resumeItem)
        pauseItem.submenu = pauseMenu
        menu.addItem(pauseItem)
    }

    private func addDurationMenu(to menu: NSMenu) {
        let durationMenu = NSMenu()
        durationMenu.autoenablesItems = false
        for duration in AppSettings.allowedToastDurations {
            let item = NSMenuItem(
                title: Self.durationTitle(duration),
                action: #selector(selectDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: duration)
            durationMenu.addItem(item)
            durationItems.append(item)
        }

        let durationItem = NSMenuItem(title: "Duration", action: nil, keyEquivalent: "")
        durationItem.submenu = durationMenu
        menu.addItem(durationItem)
    }

    private func addExcludedApplicationsMenu(to menu: NSMenu) {
        excludedApplicationsMenu.autoenablesItems = false
        excludedApplicationsMenu.delegate = self
        let excludedApplicationsItem = NSMenuItem(
            title: "Don't Show Toast For",
            action: nil,
            keyEquivalent: ""
        )
        excludedApplicationsItem.submenu = excludedApplicationsMenu
        menu.addItem(excludedApplicationsItem)
        menu.addItem(.separator())
    }

    private func addQuitItem(to menu: NSMenu) {
        let quitItem = NSMenuItem(
            title: "Quit Sidekick",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }
}
