import Foundation

func shouldSuppressClipboardToast(
    sourceApplicationBundleIdentifier: String?,
    excludedBundleIdentifiers: Set<String>
) -> Bool {
    guard let sourceApplicationBundleIdentifier else { return false }
    return excludedBundleIdentifiers.contains(sourceApplicationBundleIdentifier)
}

@MainActor
final class AppSettings {
    static let allowedToastDurations: [TimeInterval] = [1.5, 2.5, 4, 6]
    static let defaultToastDuration: TimeInterval = 2.5

    var onChange: (() -> Void)?
    var onAppearanceChange: (() -> Void)?
    var onTwitchSettingsChange: (() -> Void)?

    static let defaultScreenshotFilenameTemplate = ScreenshotFilenameTemplate.defaultTemplate
    static var defaultScreenshotSaveDirectoryURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Pictures", isDirectory: true)
    }

    private enum Key {
        static let clipboardToastEnabled = "clipboardToastEnabled"
        static let twitchNotificationsEnabled = "twitchNotificationsEnabled"
        static let twitchNotificationChannelMode = "twitchNotificationChannelMode"
        static let twitchSelectedChannelIDs = "twitchSelectedChannelIDs"
        static let twitchChannelSelections = "twitchChannelSelections"
        static let twitchKeepChannelSelectionsBetweenModes = "twitchKeepChannelSelectionsBetweenModes"
        static let twitchOAuthClientID = "twitchOAuthClientID"
        static let excludedToastApplicationBundleIdentifiers = "excludedToastApplicationBundleIdentifiers"
        static let toastDuration = "toastDuration"
        static let webPClipboardConverterEnabled = "webPClipboardConverterEnabled"
        static let clipboardImageAutoConvertToWebPEnabled = "clipboardImageAutoConvertToWebPEnabled"
        static let markdownClipboardCleanerEnabled = "markdownClipboardCleanerEnabled"
        static let clearURLsClipboardEnabled = "clearURLsClipboardEnabled"
        static let microphoneToastEnabled = "microphoneToastEnabled"
        static let clipboardImageOpeningApplicationPath = "clipboardImageOpeningApplicationPath"
        static let screenshotSaveDirectoryPath = "screenshotSaveDirectoryPath"
        static let screenshotFilenameTemplate = "screenshotFilenameTemplate"
        static let screenshotCursorIncludedByDefault = "screenshotCursorIncludedByDefault"
        static let screenshotCopyAsWebP = "screenshotCopyAsWebP"
        static let screenshotSaveAndCopyShortcut = "screenshotSaveAndCopyShortcut"
        static let appearance = "appearance"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.clipboardToastEnabled: true,
            Key.excludedToastApplicationBundleIdentifiers: [String](),
            Key.toastDuration: Self.defaultToastDuration,
            Key.webPClipboardConverterEnabled: true,
            Key.clipboardImageAutoConvertToWebPEnabled: false,
            Key.markdownClipboardCleanerEnabled: true,
            Key.clearURLsClipboardEnabled: true,
            Key.microphoneToastEnabled: true,
            Key.twitchNotificationsEnabled: false,
            Key.screenshotCursorIncludedByDefault: false,
            Key.screenshotCopyAsWebP: false,
            Key.screenshotSaveDirectoryPath: Self.defaultScreenshotSaveDirectoryURL.path,
            Key.screenshotFilenameTemplate: Self.defaultScreenshotFilenameTemplate,
            Key.appearance: AppAppearance.system.rawValue
        ])

        let storedDuration = defaults.double(forKey: Key.toastDuration)
        if !Self.allowedToastDurations.contains(storedDuration) {
            defaults.set(Self.defaultToastDuration, forKey: Key.toastDuration)
        }
    }

    var clipboardToastEnabled: Bool {
        get { defaults.bool(forKey: Key.clipboardToastEnabled) }
        set {
            guard newValue != clipboardToastEnabled else { return }
            defaults.set(newValue, forKey: Key.clipboardToastEnabled)
            onChange?()
        }
    }

    var twitchNotificationsEnabled: Bool {
        get { defaults.bool(forKey: Key.twitchNotificationsEnabled) }
        set {
            guard newValue != twitchNotificationsEnabled else { return }
            defaults.set(newValue, forKey: Key.twitchNotificationsEnabled)
            onChange?()
            onTwitchSettingsChange?()
        }
    }

    var twitchNotificationChannelMode: TwitchNotificationChannelMode {
        get {
            defaults.string(forKey: Key.twitchNotificationChannelMode)
                .flatMap(TwitchNotificationChannelMode.init(rawValue:)) ?? .all
        }
        set {
            guard newValue != twitchNotificationChannelMode else { return }
            defaults.set(newValue.rawValue, forKey: Key.twitchNotificationChannelMode)
        }
    }

    var twitchKeepChannelSelectionsBetweenModes: Bool {
        defaults.bool(forKey: Key.twitchKeepChannelSelectionsBetweenModes)
    }

    func twitchSelectedChannelIDs(for mode: TwitchNotificationChannelMode) -> Set<String> {
        guard mode != .all else { return [] }
        return channelSelectionsByMode[mode.rawValue] ?? []
    }

    func setTwitchSelectedChannelIDs(_ channelIDs: Set<String>, for mode: TwitchNotificationChannelMode) {
        guard mode != .all else { return }
        let normalized = Set(channelIDs.lazy.filter { !$0.isEmpty })
        var selections = channelSelectionsByMode
        let modesToUpdate = twitchKeepChannelSelectionsBetweenModes
            ? Self.checkableTwitchChannelModes
            : [mode]
        guard modesToUpdate.contains(where: { selections[$0.rawValue, default: []] != normalized }) else {
            return
        }
        for selectionMode in modesToUpdate {
            selections[selectionMode.rawValue] = normalized
        }
        saveTwitchChannelSelections(selections)
    }

    func setTwitchKeepChannelSelectionsBetweenModes(
        _ enabled: Bool,
        using mode: TwitchNotificationChannelMode
    ) {
        guard mode != .all, enabled != twitchKeepChannelSelectionsBetweenModes else { return }
        if enabled {
            let selectedIDs = twitchSelectedChannelIDs(for: mode)
            var selections = channelSelectionsByMode
            for selectionMode in Self.checkableTwitchChannelModes {
                selections[selectionMode.rawValue] = selectedIDs
            }
            saveTwitchChannelSelections(selections)
        }
        defaults.set(enabled, forKey: Key.twitchKeepChannelSelectionsBetweenModes)
    }

    func pruneTwitchChannelSelections(keeping channelIDs: Set<String>) {
        var selections = channelSelectionsByMode
        var didChange = false
        for mode in Self.checkableTwitchChannelModes {
            let key = mode.rawValue
            let currentIDs = selections[key, default: []]
            let remainingIDs = currentIDs.intersection(channelIDs)
            guard remainingIDs != currentIDs else { continue }
            selections[key] = remainingIDs
            didChange = true
        }
        guard didChange else { return }
        saveTwitchChannelSelections(selections)
    }

    private static let checkableTwitchChannelModes: [TwitchNotificationChannelMode] = [
        .allExceptSelected,
        .onlySelected
    ]

    private var channelSelectionsByMode: [String: Set<String>] {
        if let stored = defaults.dictionary(forKey: Key.twitchChannelSelections) as? [String: [String]] {
            return Dictionary(uniqueKeysWithValues: Self.checkableTwitchChannelModes.map {
                ($0.rawValue, Set(stored[$0.rawValue] ?? []))
            })
        }
        let legacyIDs = Set(defaults.stringArray(forKey: Key.twitchSelectedChannelIDs) ?? [])
        return Dictionary(uniqueKeysWithValues: Self.checkableTwitchChannelModes.map {
            ($0.rawValue, legacyIDs)
        })
    }

    private func saveTwitchChannelSelections(_ selections: [String: Set<String>]) {
        let stored = Dictionary(uniqueKeysWithValues: Self.checkableTwitchChannelModes.map {
            ($0.rawValue, selections[$0.rawValue, default: []].sorted())
        })
        defaults.set(stored, forKey: Key.twitchChannelSelections)
        defaults.removeObject(forKey: Key.twitchSelectedChannelIDs)
    }
    var twitchOAuthClientID: String {
        get { defaults.string(forKey: Key.twitchOAuthClientID) ?? "" }
        set {
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized != twitchOAuthClientID else { return }
            if normalized.isEmpty {
                defaults.removeObject(forKey: Key.twitchOAuthClientID)
            } else {
                defaults.set(normalized, forKey: Key.twitchOAuthClientID)
            }
            onChange?()
            onTwitchSettingsChange?()
        }
    }

    var appearance: AppAppearance {
        get {
            guard let rawValue = defaults.string(forKey: Key.appearance) else { return .system }
            return AppAppearance(rawValue: rawValue) ?? .system
        }
        set {
            guard newValue != appearance else { return }
            defaults.set(newValue.rawValue, forKey: Key.appearance)
            onAppearanceChange?()
        }
    }

    var webPClipboardConverterEnabled: Bool {
        get { defaults.bool(forKey: Key.webPClipboardConverterEnabled) }
        set {
            guard newValue != webPClipboardConverterEnabled else { return }
            defaults.set(newValue, forKey: Key.webPClipboardConverterEnabled)
            onChange?()
        }
    }

    var markdownClipboardCleanerEnabled: Bool {
        get { defaults.bool(forKey: Key.markdownClipboardCleanerEnabled) }
        set {
            guard newValue != markdownClipboardCleanerEnabled else { return }
            defaults.set(newValue, forKey: Key.markdownClipboardCleanerEnabled)
            onChange?()
        }
    }

    var microphoneToastEnabled: Bool {
        get { defaults.bool(forKey: Key.microphoneToastEnabled) }
        set {
            guard newValue != microphoneToastEnabled else { return }
            defaults.set(newValue, forKey: Key.microphoneToastEnabled)
            onChange?()
        }
    }

    var clearURLsClipboardEnabled: Bool {
        get { defaults.bool(forKey: Key.clearURLsClipboardEnabled) }
        set {
            guard newValue != clearURLsClipboardEnabled else { return }
            defaults.set(newValue, forKey: Key.clearURLsClipboardEnabled)
            onChange?()
        }
    }

    var screenshotCursorIncludedByDefault: Bool {
        get { defaults.bool(forKey: Key.screenshotCursorIncludedByDefault) }
        set {
            guard newValue != screenshotCursorIncludedByDefault else { return }
            defaults.set(newValue, forKey: Key.screenshotCursorIncludedByDefault)
            onChange?()
        }
    }

    var screenshotCopyAsWebP: Bool {
        get { defaults.bool(forKey: Key.screenshotCopyAsWebP) }
        set {
            guard newValue != screenshotCopyAsWebP else { return }
            defaults.set(newValue, forKey: Key.screenshotCopyAsWebP)
            onChange?()
        }
    }

    var screenshotSaveDirectoryURL: URL {
        get {
            URL(fileURLWithPath: defaults.string(forKey: Key.screenshotSaveDirectoryPath)
                ?? Self.defaultScreenshotSaveDirectoryURL.path, isDirectory: true)
        }
        set {
            guard newValue.isFileURL else { return }
            let normalizedURL = newValue.standardizedFileURL
            guard normalizedURL.path != screenshotSaveDirectoryURL.path else { return }
            defaults.set(normalizedURL.path, forKey: Key.screenshotSaveDirectoryPath)
            onChange?()
        }
    }

    var screenshotFilenameTemplate: String {
        get {
            defaults.string(forKey: Key.screenshotFilenameTemplate)
                ?? Self.defaultScreenshotFilenameTemplate
        }
        set {
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.defaultScreenshotFilenameTemplate
                : newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized != screenshotFilenameTemplate else { return }
            defaults.set(normalized, forKey: Key.screenshotFilenameTemplate)
            onChange?()
        }
    }

    var screenshotSaveAndCopyShortcut: GlobalHotKey.Shortcut {
        get {
            guard let stored = defaults.dictionary(forKey: Key.screenshotSaveAndCopyShortcut),
                  let keyCodeValue = stored["keyCode"] as? Int,
                  let modifiersValue = stored["modifiers"] as? Int,
                  let keyCode = UInt32(exactly: keyCodeValue),
                  let modifiers = UInt32(exactly: modifiersValue),
                  let keyName = stored["keyName"] as? String,
                  let shortcut = GlobalHotKey.Shortcut.recorded(
                    keyCode: keyCode,
                    modifiers: modifiers,
                    keyName: keyName
                  ) else {
                return .screenshotSaveAndClipboard
            }
            return shortcut
        }
        set {
            guard newValue != screenshotSaveAndCopyShortcut else { return }
            defaults.set([
                "keyCode": Int(newValue.keyCode),
                "modifiers": Int(newValue.modifiers),
                "keyName": newValue.keyName
            ], forKey: Key.screenshotSaveAndCopyShortcut)
            onChange?()
        }
    }

    var toastDuration: TimeInterval {
        get { defaults.double(forKey: Key.toastDuration) }
        set {
            let normalized = Self.allowedToastDurations.contains(newValue)
                ? newValue
                : Self.defaultToastDuration
            guard normalized != toastDuration else { return }
            defaults.set(normalized, forKey: Key.toastDuration)
            onChange?()
        }
    }

    var excludedToastApplicationBundleIdentifiers: Set<String> {
        get {
            Set(defaults.stringArray(forKey: Key.excludedToastApplicationBundleIdentifiers) ?? [])
        }
        set {
            let normalized = Set(newValue.lazy.filter { !$0.isEmpty })
            guard normalized != excludedToastApplicationBundleIdentifiers else { return }
            defaults.set(normalized.sorted(), forKey: Key.excludedToastApplicationBundleIdentifiers)
            onChange?()
        }
    }

    private static func validatedApplicationURL(_ url: URL) -> URL? {
        guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let bundle = Bundle(url: url),
              (bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String) == "APPL",
              bundle.bundleIdentifier?.isEmpty == false,
              let executableURL = bundle.executableURL,
              (try? executableURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }
        return url.standardizedFileURL
    }

    var clipboardImageOpeningApplicationURL: URL? {
        get {
            guard let path = defaults.string(forKey: Key.clipboardImageOpeningApplicationPath),
                  !path.isEmpty else {
                return nil
            }
            return Self.validatedApplicationURL(URL(fileURLWithPath: path))
        }
        set {
            let normalizedURL: URL?
            if let newValue {
                guard let validatedURL = Self.validatedApplicationURL(newValue) else { return }
                normalizedURL = validatedURL
            } else {
                normalizedURL = nil
            }
            let storedPath = defaults.string(forKey: Key.clipboardImageOpeningApplicationPath)
            guard normalizedURL?.path != storedPath else {
                return
            }
            if let normalizedURL {
                defaults.set(normalizedURL.path, forKey: Key.clipboardImageOpeningApplicationPath)
            } else {
                defaults.removeObject(forKey: Key.clipboardImageOpeningApplicationPath)
            }
            onChange?()
        }
    }
}

extension AppSettings {
    var clipboardImageAutoConvertToWebPEnabled: Bool {
        get { defaults.bool(forKey: Key.clipboardImageAutoConvertToWebPEnabled) }
        set {
            guard newValue != clipboardImageAutoConvertToWebPEnabled else { return }
            defaults.set(newValue, forKey: Key.clipboardImageAutoConvertToWebPEnabled)
            onChange?()
        }
    }
}
