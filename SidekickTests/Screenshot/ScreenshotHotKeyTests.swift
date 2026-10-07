import Carbon.HIToolbox
import XCTest

@MainActor
final class ScreenshotHotKeyTests: XCTestCase {
    func testDefaultSaveAndCopyShortcutIsConfigurableAndPersists() throws {
        let suiteName = "ScreenshotHotKeyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.screenshotSaveAndCopyShortcut.displayName, "⌘⌥⇧5")
        let shortcut = try XCTUnwrap(GlobalHotKey.Shortcut.recorded(
            keyCode: UInt32(kVK_ANSI_8),
            modifiers: UInt32(cmdKey | optionKey | controlKey),
            keyName: "8"
        ))

        settings.screenshotSaveAndCopyShortcut = shortcut

        XCTAssertEqual(AppSettings(defaults: defaults).screenshotSaveAndCopyShortcut, shortcut)
        XCTAssertEqual(shortcut.displayName, "⌘⌥⌃8")
    }

    func testConfiguredHotKeyRejectsUnsafeSelectionKeysAndUnmodifiedKeys() {
        XCTAssertNil(GlobalHotKey.Shortcut.recorded(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(cmdKey | optionKey),
            keyName: "C"
        ))
        XCTAssertNil(GlobalHotKey.Shortcut.recorded(
            keyCode: UInt32(kVK_ANSI_F),
            modifiers: UInt32(cmdKey | optionKey),
            keyName: "F"
        ))
        XCTAssertNil(GlobalHotKey.Shortcut.recorded(
            keyCode: UInt32(kVK_ANSI_Z),
            modifiers: 0,
            keyName: "Z"
        ))
        XCTAssertNil(GlobalHotKey.Shortcut.recorded(
            keyCode: UInt32(kVK_ANSI_Z),
            modifiers: UInt32(cmdKey),
            keyName: "?"
        ))
        XCTAssertNil(GlobalHotKey.Shortcut.recorded(
            keyCode: UInt32(kVK_ANSI_Q),
            modifiers: UInt32(cmdKey),
            keyName: "Q"
        ))
        XCTAssertNil(GlobalHotKey.Shortcut.recorded(
            keyCode: UInt32(kVK_ANSI_X),
            modifiers: UInt32(cmdKey),
            keyName: "X"
        ))
        XCTAssertNil(GlobalHotKey.Shortcut.recorded(
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: UInt32(cmdKey),
            keyName: "V"
        ))
        XCTAssertNotNil(GlobalHotKey.Shortcut.recorded(
            keyCode: UInt32(kVK_ANSI_Q),
            modifiers: UInt32(cmdKey | optionKey),
            keyName: "Q"
        ))
    }

    func testCarbonRegistersConfiguredHotKeyBeforeOldRegistrationIsRemoved() throws {
        let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let oldShortcut = try XCTUnwrap(GlobalHotKey.Shortcut.recorded(
            keyCode: UInt32(kVK_ANSI_Z),
            modifiers: modifiers,
            keyName: "Z"
        ))
        let replacementShortcut = try XCTUnwrap(GlobalHotKey.Shortcut.recorded(
            keyCode: UInt32(kVK_ANSI_X),
            modifiers: modifiers,
            keyName: "X"
        ))
        let oldHotKey = GlobalHotKey(shortcut: oldShortcut) {}
        let replacementHotKey = GlobalHotKey(shortcut: replacementShortcut) {}
        defer {
            oldHotKey.stop()
            replacementHotKey.stop()
        }

        XCTAssertEqual(oldHotKey.start(), noErr)
        XCTAssertEqual(replacementHotKey.start(), noErr)
    }
}
