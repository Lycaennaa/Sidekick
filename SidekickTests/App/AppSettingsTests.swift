import AppKit
import XCTest

@MainActor
final class AppSettingsTests: XCTestCase {
    func testWebPClipboardConverterDefaultsEnabledAndPersists() {
        let defaults = makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertTrue(settings.webPClipboardConverterEnabled)
        settings.webPClipboardConverterEnabled = false

        XCTAssertFalse(AppSettings(defaults: defaults).webPClipboardConverterEnabled)
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
