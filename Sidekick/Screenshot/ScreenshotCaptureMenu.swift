import AppKit

@MainActor
final class ScreenshotCaptureMenu: NSObject {
    private let onCaptureScreen: () -> Void
    private let captureScreenItem = NSMenuItem(title: "Capture Screen", action: nil, keyEquivalent: "")
    private weak var statusMenu: NSMenu?

    init(onCaptureScreen: @escaping () -> Void) {
        self.onCaptureScreen = onCaptureScreen
        super.init()
        captureScreenItem.action = #selector(captureScreen)
        captureScreenItem.target = self
    }

    func add(to menu: NSMenu) {
        statusMenu = menu
        menu.addItem(captureScreenItem)
        menu.addItem(.separator())
    }

    @objc func captureScreen() {
        statusMenu?.cancelTracking()
        DispatchQueue.main.async { [onCaptureScreen] in
            onCaptureScreen()
        }
    }
}
