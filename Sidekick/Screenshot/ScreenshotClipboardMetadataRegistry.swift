@MainActor
final class ScreenshotClipboardMetadataRegistry {
    private var registeredChangeCount: Int?
    private var registeredDynamicRange: ClipboardScreenshotDynamicRange?

    func register(_ dynamicRange: ClipboardScreenshotDynamicRange, forChangeCount changeCount: Int) {
        registeredChangeCount = changeCount
        registeredDynamicRange = dynamicRange
    }

    func dynamicRange(forChangeCount changeCount: Int) -> ClipboardScreenshotDynamicRange? {
        guard registeredChangeCount == changeCount else { return nil }
        return registeredDynamicRange
    }
}
