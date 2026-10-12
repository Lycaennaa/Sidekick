import AppKit
import XCTest

@MainActor
final class AppSettingsTests: XCTestCase {
    func testAppearanceDefaultsToSystemAndPersistsSelection() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        var generalChangeCount = 0
        var appearanceChangeCount = 0
        var twitchSettingsChangeCount = 0
        settings.onChange = { generalChangeCount += 1 }
        settings.onAppearanceChange = { appearanceChangeCount += 1 }
        settings.onTwitchSettingsChange = { twitchSettingsChangeCount += 1 }

        XCTAssertEqual(settings.appearance, .system)
        settings.appearance = .amoledBlack

        XCTAssertEqual(AppSettings(defaults: defaults).appearance, .amoledBlack)
        XCTAssertEqual(generalChangeCount, 0)
        XCTAssertEqual(appearanceChangeCount, 1)
        XCTAssertEqual(twitchSettingsChangeCount, 0)
    }

    func testAppearanceModeUsesNativeAppKitAppearances() {
        let application = NSApplication.shared
        let previousAppearance = AppTheme.appearance
        defer { AppTheme.apply(previousAppearance) }

        AppTheme.apply(.light)
        XCTAssertEqual(application.appearance?.name, NSAppearance.Name.aqua)

        AppTheme.apply(.dark)
        XCTAssertEqual(application.appearance?.name, NSAppearance.Name.darkAqua)

        AppTheme.apply(.system)
        XCTAssertNil(application.appearance)

        AppTheme.apply(.amoledBlack)
        XCTAssertEqual(application.appearance?.name, NSAppearance.Name.darkAqua)
        XCTAssertEqual(AppTheme.surface, .black)
    }

    func testSystemDarkAppearanceUsesSidekickDarkPalette() throws {
        let application = NSApplication.shared
        let previousMode = AppTheme.appearance
        let previousAppAppearance = application.appearance
        defer {
            AppTheme.apply(previousMode)
            application.appearance = previousAppAppearance
        }

        AppTheme.apply(.system)
        application.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))

        XCTAssertEqual(AppTheme.resolvedAppearance, .dark)
        let expectedSurface = NSColor(srgbRed: 18 / 255, green: 18 / 255, blue: 18 / 255, alpha: 1)
        XCTAssertTrue(AppTheme.surface.isEqual(expectedSurface))

        application.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        XCTAssertEqual(AppTheme.resolvedAppearance, .light)
    }

    func testImageConversionDefaultsEnabledAndPersists() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.imageConversionEnabled)
        settings.imageConversionEnabled = false

        XCTAssertFalse(AppSettings(defaults: defaults).imageConversionEnabled)
    }
    func testAutomaticImageConversionDefaultsOffAndPersistsIndependently() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.automaticImageConversionEnabled)
        XCTAssertTrue(settings.imageConversionEnabled)
        settings.automaticImageConversionEnabled = true

        let restored = AppSettings(defaults: defaults)
        XCTAssertTrue(restored.automaticImageConversionEnabled)
        XCTAssertTrue(restored.imageConversionEnabled)
    }

    func testImageOutputFormatDefaultsToWebPAndPersistsAVIF() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.imageOutputFormat, .webP)
        settings.imageOutputFormat = .avif

        XCTAssertEqual(AppSettings(defaults: defaults).imageOutputFormat, .avif)
    }

    func testImageSettingsMigrationPreservesExistingValues() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        defaults.set(false, forKey: "webPClipboardConverterEnabled")
        defaults.set(true, forKey: "clipboardImageAutoConvertToWebPEnabled")
        defaults.set(true, forKey: "screenshotCopyAsWebP")

        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.imageConversionEnabled)
        XCTAssertTrue(settings.automaticImageConversionEnabled)
        XCTAssertTrue(settings.screenshotCopyAsOutputFormat)
        XCTAssertNil(defaults.object(forKey: "webPClipboardConverterEnabled"))
        XCTAssertNil(defaults.object(forKey: "clipboardImageAutoConvertToWebPEnabled"))
        XCTAssertNil(defaults.object(forKey: "screenshotCopyAsWebP"))
    }

    func testMarkdownClipboardCleanerDefaultsEnabledAndPersists() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.markdownClipboardCleanerEnabled)
        settings.markdownClipboardCleanerEnabled = false

        XCTAssertFalse(AppSettings(defaults: defaults).markdownClipboardCleanerEnabled)
    }

    func testMicrophoneToastDefaultsEnabledAndPersists() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.microphoneToastEnabled)
        settings.microphoneToastEnabled = false

        XCTAssertFalse(AppSettings(defaults: defaults).microphoneToastEnabled)
    }

    func testTwitchNotificationsDefaultDisabledAndPersists() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertFalse(settings.twitchNotificationsEnabled)
        settings.twitchNotificationsEnabled = true

        XCTAssertTrue(AppSettings(defaults: defaults).twitchNotificationsEnabled)
    }

    func testTwitchChannelSelectionsAreIndependentUnlessKeptBetweenModes() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.twitchNotificationChannelMode, .all)
        XCTAssertFalse(settings.twitchKeepChannelSelectionsBetweenModes)
        settings.twitchNotificationChannelMode = .allExceptSelected
        settings.setTwitchSelectedChannelIDs(["excluded"], for: .allExceptSelected)
        settings.setTwitchSelectedChannelIDs(["included"], for: .onlySelected)
        XCTAssertEqual(settings.twitchSelectedChannelIDs(for: .allExceptSelected), ["excluded"])
        XCTAssertEqual(settings.twitchSelectedChannelIDs(for: .onlySelected), ["included"])

        settings.setTwitchKeepChannelSelectionsBetweenModes(true, using: .allExceptSelected)
        XCTAssertEqual(settings.twitchSelectedChannelIDs(for: .onlySelected), ["excluded"])
        settings.setTwitchSelectedChannelIDs(["shared"], for: .onlySelected)
        XCTAssertEqual(settings.twitchSelectedChannelIDs(for: .allExceptSelected), ["shared"])

        settings.setTwitchKeepChannelSelectionsBetweenModes(false, using: .onlySelected)
        settings.setTwitchSelectedChannelIDs(["only"], for: .onlySelected)
        XCTAssertEqual(settings.twitchSelectedChannelIDs(for: .allExceptSelected), ["shared"])
        XCTAssertEqual(AppSettings(defaults: defaults).twitchSelectedChannelIDs(for: .onlySelected), ["only"])
    }

    func testTwitchChannelFilterChangesDoNotTriggerGlobalSettingsChange() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        var changeCount = 0
        settings.onChange = { changeCount += 1 }

        settings.twitchNotificationChannelMode = .allExceptSelected
        settings.setTwitchSelectedChannelIDs(["stale"], for: .allExceptSelected)
        settings.setTwitchKeepChannelSelectionsBetweenModes(true, using: .allExceptSelected)
        settings.setTwitchSelectedChannelIDs(["retained", "stale"], for: .onlySelected)
        settings.setTwitchKeepChannelSelectionsBetweenModes(false, using: .onlySelected)
        settings.pruneTwitchChannelSelections(keeping: ["retained"])

        XCTAssertEqual(changeCount, 0)
    }

    func testLegacySharedChannelSelectionMigratesAndUnfollowedIDsArePruned() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        defaults.set(["legacy-id"], forKey: "twitchSelectedChannelIDs")
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.twitchSelectedChannelIDs(for: .allExceptSelected), ["legacy-id"])
        XCTAssertEqual(settings.twitchSelectedChannelIDs(for: .onlySelected), ["legacy-id"])
        settings.setTwitchSelectedChannelIDs(["legacy-id", "unfollowed-id"], for: .onlySelected)
        XCTAssertNil(defaults.object(forKey: "twitchSelectedChannelIDs"))
        settings.pruneTwitchChannelSelections(keeping: ["legacy-id"])

        XCTAssertEqual(settings.twitchSelectedChannelIDs(for: .allExceptSelected), ["legacy-id"])
        XCTAssertEqual(settings.twitchSelectedChannelIDs(for: .onlySelected), ["legacy-id"])
    }

    func testTwitchOAuthClientIDDefaultsEmptyAndPersistsTrimmedOverride() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        var changeCount = 0
        settings.onChange = { changeCount += 1 }

        XCTAssertEqual(settings.twitchOAuthClientID, "")
        settings.twitchOAuthClientID = "  app-client-id \n"

        XCTAssertEqual(AppSettings(defaults: defaults).twitchOAuthClientID, "app-client-id")
        XCTAssertEqual(changeCount, 1)

        settings.twitchOAuthClientID = " \n "
        XCTAssertEqual(settings.twitchOAuthClientID, "")
        XCTAssertNil(defaults.string(forKey: "twitchOAuthClientID"))
        XCTAssertEqual(changeCount, 2)
    }

    func testExcludedApplicationsPersist() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)

        settings.excludedToastApplicationBundleIdentifiers = [
            "com.apple.Safari",
            "com.apple.TextEdit"
        ]

        let reloadedSettings = AppSettings(defaults: defaults)
        XCTAssertEqual(
            reloadedSettings.excludedToastApplicationBundleIdentifiers,
            ["com.apple.Safari", "com.apple.TextEdit"]
        )
    }

    func testSuppressionRequiresMatchingAttributedBundleIdentifier() {
        let excluded = Set(["com.apple.Safari"])

        XCTAssertTrue(
            shouldSuppressClipboardToast(
                sourceApplicationBundleIdentifier: "com.apple.Safari",
                excludedBundleIdentifiers: excluded
            )
        )
        XCTAssertFalse(
            shouldSuppressClipboardToast(
                sourceApplicationBundleIdentifier: "com.apple.finder",
                excludedBundleIdentifiers: excluded
            )
        )
        XCTAssertFalse(
            shouldSuppressClipboardToast(
                sourceApplicationBundleIdentifier: nil,
                excludedBundleIdentifiers: excluded
            )
        )
    }

    func testClearURLsClipboardCleanerDefaultsEnabledAndPersists() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.clearURLsClipboardEnabled)
        settings.clearURLsClipboardEnabled = false

        XCTAssertFalse(AppSettings(defaults: defaults).clearURLsClipboardEnabled)
    }

    func testClipboardImageOpeningApplicationURLDefaultsToSystemDefaultAndPersists() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        let applicationURL = try XCTUnwrap(
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview")
        )

        XCTAssertNil(settings.clipboardImageOpeningApplicationURL)
        settings.clipboardImageOpeningApplicationURL = applicationURL

        XCTAssertEqual(
            AppSettings(defaults: defaults).clipboardImageOpeningApplicationURL,
            applicationURL
        )
        settings.clipboardImageOpeningApplicationURL = nil
        XCTAssertNil(AppSettings(defaults: defaults).clipboardImageOpeningApplicationURL)
    }

    func testInvalidClipboardImageOpeningApplicationURLIsIgnored() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        let invalidApplicationURL = URL(fileURLWithPath: "/Applications/MissingImageViewer.app")

        settings.clipboardImageOpeningApplicationURL = invalidApplicationURL

        XCTAssertNil(settings.clipboardImageOpeningApplicationURL)
    }

    func testClearingStaleClipboardImageOpeningApplicationURLRemovesStoredPath() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let stalePath = "/Applications/MissingImageViewer.app"
        defaults.set(stalePath, forKey: "clipboardImageOpeningApplicationPath")
        let settings = AppSettings(defaults: defaults)

        XCTAssertNil(settings.clipboardImageOpeningApplicationURL)
        settings.clipboardImageOpeningApplicationURL = nil

        XCTAssertNil(defaults.string(forKey: "clipboardImageOpeningApplicationPath"))
    }

    func testScreenshotCursorDefaultIsOffAndPersistsChanges() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        var changeCount = 0
        settings.onChange = { changeCount += 1 }

        XCTAssertFalse(settings.screenshotCursorIncludedByDefault)
        settings.screenshotCursorIncludedByDefault = true

        XCTAssertTrue(AppSettings(defaults: defaults).screenshotCursorIncludedByDefault)
        XCTAssertEqual(changeCount, 1)
    }

    func testScreenshotCopyAsOutputFormatDefaultsOffAndPersistsChanges() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        var changeCount = 0
        settings.onChange = { changeCount += 1 }

        XCTAssertFalse(settings.screenshotCopyAsOutputFormat)
        settings.screenshotCopyAsOutputFormat = true

        XCTAssertTrue(AppSettings(defaults: defaults).screenshotCopyAsOutputFormat)
        XCTAssertEqual(changeCount, 1)
    }

    func testScreenshotSaveSettingsDefaultAndPersistChanges() throws {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var changeCount = 0
        settings.onChange = { changeCount += 1 }

        XCTAssertEqual(settings.screenshotSaveDirectoryURL, AppSettings.defaultScreenshotSaveDirectoryURL)
        XCTAssertEqual(settings.screenshotFilenameTemplate, AppSettings.defaultScreenshotFilenameTemplate)
        settings.screenshotSaveDirectoryURL = directory
        settings.screenshotFilenameTemplate = "Shot_{date}_{windowTitle}"

        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.screenshotSaveDirectoryURL.path, directory.standardizedFileURL.path)
        XCTAssertEqual(restored.screenshotFilenameTemplate, "Shot_{date}_{windowTitle}")
        XCTAssertEqual(changeCount, 2)
    }
    private var defaultsSuiteName: String {
        "AppSettingsTests"
    }

    private func makeDefaults() -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            preconditionFailure("Unable to create test defaults suite")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}
