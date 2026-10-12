import AppKit
import XCTest

func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("ClipboardImageConversionTests-\(UUID().uuidString)"))
}
@MainActor
func makeTransactionalPasteboard() -> PasteboardSnapshotFakePasteboard {
    PasteboardSnapshotFakePasteboard(items: [])
}

func pngData(width: Int, height: Int) throws -> Data {
    let bitmap = try XCTUnwrap(
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        )
    )
    return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
}

func temporaryDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".kilo-tmp/ClipboardImageConversionTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
final class GenerationChangingPasteboard: PasteboardAccess {
    private var generation = 1
    private var changeCountReads = 0
    private var items: [NSPasteboardItem]
    private let replacementItems: [NSPasteboardItem]

    init(items: [NSPasteboardItem], replacementItems: [NSPasteboardItem]) {
        self.items = items
        self.replacementItems = replacementItems
    }

    var changeCount: Int {
        changeCountReads += 1
        // Third read is the old install sample and the new pre-install guard.
        if changeCountReads == 3 {
            generation += 1
            items = replacementItems
        }
        return generation
    }

    var pasteboardItems: [NSPasteboardItem]? {
        items
    }

    @discardableResult
    func clearContents() -> Int {
        generation += 1
        items = []
        return generation
    }

    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool {
        items = objects.compactMap { $0 as? NSPasteboardItem }
        return true
    }
}
@MainActor
func convert(with controller: ClipboardImageConversionController) async -> ClipboardImageConversionController.Result {
    await withCheckedContinuation { continuation in
        controller.convertClipboardImage { result in
            continuation.resume(returning: result)
        }
    }
}
