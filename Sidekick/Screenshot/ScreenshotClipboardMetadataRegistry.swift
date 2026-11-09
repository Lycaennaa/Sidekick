import Foundation

@MainActor
final class ScreenshotClipboardMetadataRegistry {
    private var registeredScreenshotChangeCount: Int?

    func registerScreenshot(forChangeCount changeCount: Int) {
        registeredScreenshotChangeCount = changeCount
    }

    func isScreenshot(forChangeCount changeCount: Int) -> Bool {
        registeredScreenshotChangeCount == changeCount
    }
}
