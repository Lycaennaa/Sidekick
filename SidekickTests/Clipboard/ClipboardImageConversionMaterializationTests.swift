import AppKit
import XCTest

@MainActor
final class ClipboardImageConversionMaterializationTests: XCTestCase {
    func testConversionReusesSourcePayloadForRollbackSnapshot() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let imageData = try pngData(width: 3, height: 2)
        XCTAssertTrue(pasteboard.setData(imageData, forType: .png))
        let sourceItem = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        let reader = CountingImagePayloadReader(sourceItem: sourceItem)
        let controller = ClipboardImageConversionController(
            pasteboard: pasteboard,
            outputDirectory: directory,
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: reader,
            onMessage: { _ in }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        let result = await convert(with: controller)
        guard case let .converted(url) = result else {
            return XCTFail("Expected clipboard image conversion, got \(result)")
        }

        XCTAssertEqual(
            reader.sourceItemPNGReadCount,
            2,
            "One capture materialization and one pre-mutation content revalidation are expected"
        )
        XCTAssertEqual(pasteboard.string(forType: .fileURL), url.absoluteString)
    }
}

@MainActor
private final class CountingImagePayloadReader: PasteboardPayloadReading {
    private let sourceItem: ObjectIdentifier
    private(set) var sourceItemPNGReadCount = 0

    init(sourceItem: NSPasteboardItem) {
        self.sourceItem = ObjectIdentifier(sourceItem)
    }

    func readData(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int
    ) async -> PasteboardPayloadReader.Result {
        if ObjectIdentifier(item) == sourceItem, type == .png {
            sourceItemPNGReadCount += 1
        }
        guard !Task.isCancelled, maximumBytes >= 0 else { return .missing }
        guard let data = item.data(forType: type) else { return .missing }
        guard data.count <= maximumBytes else {
            return .tooLarge(byteCount: data.count)
        }
        return .data(data)
    }
}
