import AppKit

@MainActor
final class ScreenshotCaptureMenu: NSObject {
    private let settings: AppSettings
    private let onCaptureScreenshot: (Bool?) -> Void
    private let captureItem = NSMenuItem(title: "Capture Display to Clipboard", action: nil, keyEquivalent: "")
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
    private weak var statusMenu: NSMenu?

    init(settings: AppSettings, onCaptureScreenshot: @escaping (Bool?) -> Void) {
        self.settings = settings
        self.onCaptureScreenshot = onCaptureScreenshot
        super.init()

        captureItem.action = #selector(captureUsingDefaultCursorSetting)
        captureItem.target = self
        includeCursorByDefaultItem.action = #selector(toggleCursorDefault)
        includeCursorByDefaultItem.target = self
        captureWithCursorItem.action = #selector(captureWithCursor)
        captureWithCursorItem.target = self
        captureWithoutCursorItem.action = #selector(captureWithoutCursor)
        captureWithoutCursorItem.target = self

        let cursorMenu = NSMenu()
        cursorMenu.autoenablesItems = false
        cursorMenu.addItem(includeCursorByDefaultItem)
        cursorMenu.addItem(.separator())
        cursorMenu.addItem(captureWithCursorItem)
        cursorMenu.addItem(captureWithoutCursorItem)
        cursorOptionsItem.submenu = cursorMenu
    }

    func add(to menu: NSMenu) {
        statusMenu = menu
        menu.addItem(captureItem)
        menu.addItem(cursorOptionsItem)
        menu.addItem(.separator())
        refresh()
    }

    func refresh() {
        includeCursorByDefaultItem.state = settings.screenshotCursorIncludedByDefault ? .on : .off
    }

    @objc private func captureUsingDefaultCursorSetting() {
        capture(cursorOverride: nil)
    }

    @objc private func toggleCursorDefault() {
        settings.screenshotCursorIncludedByDefault.toggle()
    }

    @objc private func captureWithCursor() {
        capture(cursorOverride: true)
    }

    @objc private func captureWithoutCursor() {
        capture(cursorOverride: false)
    }

    private func capture(cursorOverride: Bool?) {
        statusMenu?.cancelTracking()
        DispatchQueue.main.async { [onCaptureScreenshot] in
            onCaptureScreenshot(cursorOverride)
        }
    }
}
