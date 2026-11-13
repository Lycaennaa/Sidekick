import Foundation

enum TwitchToastTiming {
    static let key = "twitchToastDuration"
    static let durationPresets: [TimeInterval] = [4, 6, 8, 10, 15]
    static let defaultDuration: TimeInterval = 10

    static func normalized(_ duration: TimeInterval) -> TimeInterval {
        duration.isFinite && duration > 0 ? duration : defaultDuration
    }
}

enum TwitchPollFrequency {
    static let key = "twitchPollInterval"
    static let minimumInterval: TimeInterval = 30
    static let defaultInterval: TimeInterval = 150
    static let intervalPresets: [TimeInterval] = [30, 60, 150, 300, 600]
    static let maximumInterval = TimeInterval(UInt64.max / 1_000_000_000)

    static func normalized(_ interval: TimeInterval) -> TimeInterval {
        guard interval.isFinite else { return defaultInterval }
        return min(max(interval, minimumInterval), maximumInterval)
    }
}

extension AppSettings {
    static var twitchToastDurationPresets: [TimeInterval] {
        TwitchToastTiming.durationPresets
    }

    static var defaultTwitchToastDuration: TimeInterval {
        TwitchToastTiming.defaultDuration
    }

    var twitchToastDuration: TimeInterval {
        get { TwitchToastTiming.normalized(defaults.double(forKey: TwitchToastTiming.key)) }
        set {
            let normalized = TwitchToastTiming.normalized(newValue)
            guard normalized != twitchToastDuration else { return }
            defaults.set(normalized, forKey: TwitchToastTiming.key)
            onChange?()
        }
    }

    var twitchPollInterval: TimeInterval {
        get { TwitchPollFrequency.normalized(defaults.double(forKey: TwitchPollFrequency.key)) }
        set {
            let normalized = TwitchPollFrequency.normalized(newValue)
            guard normalized != twitchPollInterval else { return }
            defaults.set(normalized, forKey: TwitchPollFrequency.key)
            onChange?()
            onTwitchSettingsChange?()
        }
    }

    private func imageQuality(forKey key: String, fallback: Double) -> Double {
        let stored = defaults.double(forKey: key)
        return ClipboardImageConversionPolicy.isValidQuality(stored) ? stored : fallback
    }

    private func setImageQuality(_ quality: Double, forKey key: String, fallback: Double) {
        let normalized = ClipboardImageConversionPolicy.isValidQuality(quality) ? quality : fallback
        guard normalized != defaults.double(forKey: key) else { return }
        defaults.set(normalized, forKey: key)
        onChange?()
    }

    var clipboardImageQuality: Double {
        get { imageQuality(forKey: Key.clipboardImageQuality, fallback: ClipboardImageConversionPolicy.quality) }
        set {
            setImageQuality(
                newValue,
                forKey: Key.clipboardImageQuality,
                fallback: ClipboardImageConversionPolicy.quality
            )
        }
    }

    var screenshotImageQuality: Double {
        get {
            imageQuality(
                forKey: Key.screenshotImageQuality,
                fallback: ClipboardImageConversionPolicy.screenshotQuality
            )
        }
        set {
            setImageQuality(
                newValue,
                forKey: Key.screenshotImageQuality,
                fallback: ClipboardImageConversionPolicy.screenshotQuality
            )
        }
    }

    var toastDuration: TimeInterval {
        get {
            let stored = defaults.double(forKey: Key.toastDuration)
            return stored.isFinite && stored > 0 ? stored : Self.defaultToastDuration
        }
        set {
            let normalized = newValue.isFinite && newValue > 0
                ? newValue
                : Self.defaultToastDuration
            guard normalized != toastDuration else { return }
            defaults.set(normalized, forKey: Key.toastDuration)
            onChange?()
        }
    }
}
