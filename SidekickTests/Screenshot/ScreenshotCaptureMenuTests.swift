import AppKit
import Carbon.HIToolbox
import XCTest

@MainActor
final class ScreenshotCaptureMenuTests: XCTestCase {
    private struct MenuAction {
        let title: String
        let menu: NSMenu
        let selector: Selector
        let mode: ScreenshotCaptureMode
        let cursor: Bool?
        let perform: @MainActor () -> Void
    }

    private var invocations: [(ScreenshotCaptureMode, Bool?)] = []
    private var nextExpectation: XCTestExpectation?

    func testStatusMenuExposesCursorAndSavePlusCopyOverrides() async throws {
        let suiteName = "ScreenshotCaptureMenuTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        invocations = []
        let screenshotMenu = ScreenshotCaptureMenu(
            settings: settings,
            onCaptureScreenshot: { [weak self] mode, cursorOverride in
                self?.invocations.append((mode, cursorOverride))
                self?.nextExpectation?.fulfill()
            },
            onCaptureWindow: {}
        )
        let menu = NSMenu()
        screenshotMenu.add(to: menu)
        let cursorItem = try XCTUnwrap(menu.items.first { $0.title == "Screenshot Cursor Options" })
        let cursorMenu = try XCTUnwrap(cursorItem.submenu)
        for action in menuActions(menu: menu, cursorMenu: cursorMenu, screenshotMenu: screenshotMenu) {
            let item = try XCTUnwrap(action.menu.items.first { $0.title == action.title })
            await invoke(item, action: action, target: screenshotMenu)
        }

        let customShortcut = try XCTUnwrap(GlobalHotKey.Shortcut.recorded(
            keyCode: 28,
            modifiers: UInt32(cmdKey | controlKey),
            keyName: "8"
        ))
        settings.screenshotSaveAndCopyShortcut = customShortcut
        screenshotMenu.refresh()
        XCTAssertEqual(
            menu.items.first { $0.title.hasPrefix("Save Screenshot and Copy") }?.title,
            "Save Screenshot and Copy (⌘⌃8)"
        )
        let defaultItem = try XCTUnwrap(cursorMenu.items.first { $0.title == "Include Cursor by Default" })
        XCTAssertTrue(defaultItem.target === screenshotMenu)
        XCTAssertEqual(defaultItem.action, #selector(ScreenshotCaptureMenu.toggleCursorDefault) as Selector?)
        XCTAssertFalse(settings.screenshotCursorIncludedByDefault)
        screenshotMenu.toggleCursorDefault()
        XCTAssertTrue(settings.screenshotCursorIncludedByDefault)
    }

    private func menuActions(
        menu: NSMenu,
        cursorMenu: NSMenu,
        screenshotMenu: ScreenshotCaptureMenu
    ) -> [MenuAction] {
        [
            MenuAction(
                title: "Capture Display to Clipboard",
                menu: menu,
                selector: #selector(ScreenshotCaptureMenu.captureUsingDefaultCursorSetting),
                mode: .copy,
                cursor: nil,
                perform: screenshotMenu.captureUsingDefaultCursorSetting
            ),
            MenuAction(
                title: "Save Screenshot and Copy (⌘⌥⇧5)",
                menu: menu,
                selector: #selector(ScreenshotCaptureMenu.saveAndCopy),
                mode: .saveAndCopy,
                cursor: nil,
                perform: screenshotMenu.saveAndCopy
            ),
            MenuAction(
                title: "Capture with Cursor",
                menu: cursorMenu,
                selector: #selector(ScreenshotCaptureMenu.captureWithCursor),
                mode: .copy,
                cursor: true,
                perform: screenshotMenu.captureWithCursor
            ),
            MenuAction(
                title: "Capture without Cursor",
                menu: cursorMenu,
                selector: #selector(ScreenshotCaptureMenu.captureWithoutCursor),
                mode: .copy,
                cursor: false,
                perform: screenshotMenu.captureWithoutCursor
            ),
            MenuAction(
                title: "Save and copy with Cursor",
                menu: cursorMenu,
                selector: #selector(ScreenshotCaptureMenu.saveAndCopyWithCursor),
                mode: .saveAndCopy,
                cursor: true,
                perform: screenshotMenu.saveAndCopyWithCursor
            ),
            MenuAction(
                title: "Save and copy without Cursor",
                menu: cursorMenu,
                selector: #selector(ScreenshotCaptureMenu.saveAndCopyWithoutCursor),
                mode: .saveAndCopy,
                cursor: false,
                perform: screenshotMenu.saveAndCopyWithoutCursor
            )
        ]
    }

    private func invoke(_ item: NSMenuItem, action: MenuAction, target: ScreenshotCaptureMenu) async {
        XCTAssertTrue(item.target === target)
        XCTAssertEqual(item.action, action.selector as Selector?)
        let callback = expectation(description: "Screenshot menu callback")
        nextExpectation = callback
        action.perform()
        await fulfillment(of: [callback], timeout: 2)
        XCTAssertEqual(invocations.last?.0, action.mode)
        XCTAssertEqual(invocations.last?.1, action.cursor)
    }
}
