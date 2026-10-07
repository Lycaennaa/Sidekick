import AppKit
import XCTest

@MainActor
final class AudioSettingsViewTests: XCTestCase {
    func testToastOptionsTrackMicrophoneNotificationSetting() throws {
        let suiteName = "AudioSettingsViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        let menu = NSMenu()
        settings.microphoneToastEnabled = false
        let view = AudioSettingsView(settings: settings, microphoneToastOptionsMenu: menu)
        let optionsButton = try XCTUnwrap(findButton("Toast Options…", in: view))

        XCTAssertFalse(optionsButton.isEnabled)
        settings.microphoneToastEnabled = true
        view.refresh()
        XCTAssertTrue(optionsButton.isEnabled)
    }

    private func findButton(_ title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let button = findButton(title, in: subview) {
                return button
            }
        }
        return nil
    }
}
