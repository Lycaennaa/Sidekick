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

    private enum Key {
        static let clipboardToastEnabled = "clipboardToastEnabled"
        static let twitchNotificationsEnabled = "twitchNotificationsEnabled"
        static let twitchOAuthClientID = "twitchOAuthClientID"
        static let excludedToastApplicationBundleIdentifiers = "excludedToastApplicationBundleIdentifiers"
        static let toastDuration = "toastDuration"
        static let webPClipboardConverterEnabled = "webPClipboardConverterEnabled"
        static let markdownClipboardCleanerEnabled = "markdownClipboardCleanerEnabled"
        static let clearURLsClipboardEnabled = "clearURLsClipboardEnabled"
        static let microphoneToastEnabled = "microphoneToastEnabled"
        static let clipboardImageOpeningApplicationPath = "clipboardImageOpeningApplicationPath"
        static let screenshotCursorIncludedByDefault = "screenshotCursorIncludedByDefault"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.clipboardToastEnabled: true,
            Key.excludedToastApplicationBundleIdentifiers: [String](),
            Key.toastDuration: Self.defaultToastDuration,
            Key.webPClipboardConverterEnabled: true,
            Key.markdownClipboardCleanerEnabled: true,
            Key.clearURLsClipboardEnabled: true,
            Key.microphoneToastEnabled: true,
            Key.twitchNotificationsEnabled: false,
            Key.screenshotCursorIncludedByDefault: false
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
        }
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
