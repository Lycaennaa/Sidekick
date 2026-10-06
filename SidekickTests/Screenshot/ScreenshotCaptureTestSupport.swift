import AppKit

enum ScreenshotCaptureTestSupport {
    static func capturedScreenshot(from image: CGImage) -> CapturedDisplayScreenshot {
        CapturedDisplayScreenshot(
            image: image,
            displayID: 0,
            screenFrame: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        )
    }

    static func makePixelImage() -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: 1,
                  height: 1,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return nil
        }
        return context.makeImage()
    }
    @MainActor
    final class ScreenshotRacePasteboard: PasteboardAccess {
        var changeCount = 1
        var pasteboardItems: [NSPasteboardItem]? { nil }
        private(set) var value: String
        private(set) var writeCount = 0

        init(value: String) {
            self.value = value
        }

        func replaceContents(_ value: String) {
            self.value = value
            changeCount += 1
        }

        func clearContents() -> Int {
            value = ""
            changeCount += 1
            return changeCount
        }

        func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool {
            writeCount += 1
            changeCount += 1
            return true
        }
    }
}
