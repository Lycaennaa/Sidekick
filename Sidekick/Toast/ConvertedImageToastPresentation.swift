import AppKit

struct ScreenshotCopyToastContext: Equatable {
    let sourceChangeCount: Int
    let savedURL: URL?
    let isDismissed: Bool

    init(sourceChangeCount: Int, savedURL: URL?, isDismissed: Bool = false) {
        self.sourceChangeCount = sourceChangeCount
        self.savedURL = savedURL
        self.isDismissed = isDismissed
    }

    func markingDismissed() -> Self {
        Self(sourceChangeCount: sourceChangeCount, savedURL: savedURL, isDismissed: true)
    }

    func convertedToastCopyContext(
        ifCurrent current: ScreenshotCopyToastContext?
    ) -> ConvertedImageToastCopyContext? {
        guard let current,
              current.sourceChangeCount == sourceChangeCount else {
            return .converted
        }
        guard current == self, !current.isDismissed else { return nil }
        return .screenshot(self)
    }

    func convertedSummary(to url: URL) -> String {
        if savedURL == nil {
            return "Screenshot copied and converted to \(url.lastPathComponent)."
        }
        return "Screenshot saved, copied, and converted to \(url.lastPathComponent)."
    }
}

enum ConvertedImageToastCopyContext: Equatable {
    case converted
    case clipboardImage(sourceChangeCount: Int)
    case screenshot(ScreenshotCopyToastContext)

    var isScreenshot: Bool {
        if case .screenshot = self { return true }
        return false
    }

    var detail: String? {
        guard case let .screenshot(context) = self else { return nil }
        return context.savedURL?.lastPathComponent
    }

    func summary(to url: URL) -> String {
        switch self {
        case .converted:
            return "Converted image to \(url.lastPathComponent)"
        case .clipboardImage:
            return "Image copied and converted to \(url.lastPathComponent)."
        case let .screenshot(context):
            return context.convertedSummary(to: url)
        }
    }
}

@MainActor
enum ConvertedImageToastPresentation {
    static func model(
        url: URL,
        generation: UInt64,
        copyContext: ConvertedImageToastCopyContext,
        icon: NSImage,
        enrichment: ClipboardImageEnrichment?
    ) -> ToastModel {
        ToastModel(
            generation: generation,
            presentationStyle: .image,
            summary: copyContext.summary(to: url),
            detail: copyContext.detail,
            icon: icon,
            showsImagePreview: enrichment != nil,
            footer: enrichment?.imageFooter
        )
    }
}
