import AppKit
import Carbon.HIToolbox
import XCTest

@MainActor
final class ScreenshotHotKeyRecorderTests: XCTestCase {
    func testRecorderRejectsHUDKeyAndAcceptsModifiedHotKey() throws {
        var selectedShortcut: GlobalHotKey.Shortcut?
        var recordingTransitions: [Bool] = []
        let recorder = ScreenshotHotKeyRecorderView(
            shortcut: .screenshotSaveAndClipboard,
            onShortcutChange: { selectedShortcut = $0; return true },
            onRecordingChanged: { recordingTransitions.append($0) }
        )
        recorder.beginRecording()
        recorder.keyDown(with: try keyEvent(keyCode: Int(kVK_ANSI_C), character: "c"))
        XCTAssertNil(selectedShortcut)

        recorder.keyDown(with: try keyEvent(keyCode: Int(kVK_ANSI_8), character: "8"))

        XCTAssertEqual(selectedShortcut?.displayName, "⌘⌥⇧8")
        XCTAssertEqual(recordingTransitions, [true, false])
    }

    private func keyEvent(keyCode: Int, character: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .option, .shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
    }
}
