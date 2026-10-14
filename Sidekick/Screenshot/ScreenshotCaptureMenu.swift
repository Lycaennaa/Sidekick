import AppKit

@MainActor
final class ScreenshotCaptureMenu: NSObject {
    private let settings: AppSettings
    private let onCaptureScreenshot: (ScreenshotCaptureMode, Bool?) -> Void
    private let onCaptureWindow: () -> Void
    private let captureItem = NSMenuItem(title: "Capture Display to Clipboard", action: nil, keyEquivalent: "")
    private let captureWindowItem = NSMenuItem(title: "Capture Window to Clipboard", action: nil, keyEquivalent: "")
    private let saveAndCopyItem = NSMenuItem(
        title: "Save Screenshot and Copy",
        action: nil,
        keyEquivalent: ""
    )
    private let cursorOptionsItem = NSMenuItem(
        title: "Screenshot Cursor Options",
        action: nil,
        keyEquivalent: ""
    )
    private let includeCursorByDefaultItem = NSMenuItem(
        title: "Include Cursor by Default",
        action: nil,
        keyEquivalent: ""
    )
    private let captureWithCursorItem = NSMenuItem(
        title: "Capture with Cursor",
        action: nil,
        keyEquivalent: ""
    )
    private let captureWithoutCursorItem = NSMenuItem(
        title: "Capture without Cursor",
        action: nil,
        keyEquivalent: ""
    )
    private let saveAndCopyWithCursorItem = NSMenuItem(
        title: "Save and copy with Cursor",
        action: nil,
        keyEquivalent: ""
    )
    private let saveAndCopyWithoutCursorItem = NSMenuItem(
        title: "Save and copy without Cursor",
        action: nil,
        keyEquivalent: ""
    )
    private weak var statusMenu: NSMenu?

    init(
        settings: AppSettings,
        onCaptureScreenshot: @escaping (ScreenshotCaptureMode, Bool?) -> Void,
        onCaptureWindow: @escaping () -> Void
    ) {
        self.settings = settings
        self.onCaptureScreenshot = onCaptureScreenshot
        self.onCaptureWindow = onCaptureWindow
        super.init()

        captureItem.action = #selector(captureUsingDefaultCursorSetting)
        captureWindowItem.action = #selector(captureWindow)
        captureWindowItem.target = self
        captureItem.target = self
        saveAndCopyItem.action = #selector(saveAndCopy)
        saveAndCopyItem.target = self
        includeCursorByDefaultItem.action = #selector(toggleCursorDefault)
        includeCursorByDefaultItem.target = self
        captureWithCursorItem.action = #selector(captureWithCursor)
        captureWithCursorItem.target = self
        captureWithoutCursorItem.action = #selector(captureWithoutCursor)
        captureWithoutCursorItem.target = self
        saveAndCopyWithCursorItem.action = #selector(saveAndCopyWithCursor)
        saveAndCopyWithCursorItem.target = self
        saveAndCopyWithoutCursorItem.action = #selector(saveAndCopyWithoutCursor)
        saveAndCopyWithoutCursorItem.target = self

        let cursorMenu = NSMenu()
        cursorMenu.autoenablesItems = false
        cursorMenu.addItem(includeCursorByDefaultItem)
        cursorMenu.addItem(.separator())
        cursorMenu.addItem(captureWithCursorItem)
        cursorMenu.addItem(captureWithoutCursorItem)
        cursorMenu.addItem(.separator())
        cursorMenu.addItem(saveAndCopyWithCursorItem)
        cursorMenu.addItem(saveAndCopyWithoutCursorItem)
        cursorOptionsItem.submenu = cursorMenu
    }

    func add(to menu: NSMenu) {
        statusMenu = menu
        menu.addItem(captureItem)
        menu.addItem(captureWindowItem)
        menu.addItem(saveAndCopyItem)
        menu.addItem(.separator())
        menu.addItem(cursorOptionsItem)
        refresh()
    }

    func refresh() {
        saveAndCopyItem.title = "Save Screenshot and Copy (\(settings.screenshotSaveAndCopyShortcut.displayName))"
        includeCursorByDefaultItem.state = settings.screenshotCursorIncludedByDefault ? .on : .off
    }

    @objc func captureUsingDefaultCursorSetting() {
        capture(mode: .copy, cursorOverride: nil)
    }

    @objc func captureWindow() {
        statusMenu?.cancelTracking()
        DispatchQueue.main.async { [onCaptureWindow] in
            onCaptureWindow()
        }
    }

    @objc func saveAndCopy() {
        capture(mode: .saveAndCopy, cursorOverride: nil)
    }

    @objc func toggleCursorDefault() {
        settings.screenshotCursorIncludedByDefault.toggle()
    }

    @objc func captureWithCursor() {
        capture(mode: .copy, cursorOverride: true)
    }

    @objc func captureWithoutCursor() {
        capture(mode: .copy, cursorOverride: false)
    }

    @objc func saveAndCopyWithCursor() {
        capture(mode: .saveAndCopy, cursorOverride: true)
    }

    @objc func saveAndCopyWithoutCursor() {
        capture(mode: .saveAndCopy, cursorOverride: false)
    }

    private func capture(mode: ScreenshotCaptureMode, cursorOverride: Bool?) {
        statusMenu?.cancelTracking()
        DispatchQueue.main.async { [onCaptureScreenshot] in
            onCaptureScreenshot(mode, cursorOverride)
        }
    }
}
