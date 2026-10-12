import AppKit
import XCTest

@MainActor
final class PasteboardPayloadReaderTests: XCTestCase {
    private let limits = PasteboardSnapshot.Limits(
        maximumBytes: 16,
        maximumItems: 2,
        maximumTypesPerItem: 2
    )

    func testBoundedItemsPreservesValidInputsAndRejectsOverflow() {
        let validPasteboard = PasteboardSnapshotFakePasteboard(items: [
            makePasteboardSnapshotItem(text: "one"),
            makePasteboardSnapshotItem(text: "two")
        ])
        let validItems = PasteboardSnapshot.boundedItems(
            from: validPasteboard,
            maximumItems: limits.maximumItems,
            rejectingOverflow: true
        )
        XCTAssertEqual(validItems?.count, limits.maximumItems)

        let overflowPasteboard = PasteboardSnapshotFakePasteboard(items: [
            makePasteboardSnapshotItem(text: "one"),
            makePasteboardSnapshotItem(text: "two"),
            makePasteboardSnapshotItem(text: "three")
        ])
        XCTAssertNil(PasteboardSnapshot.boundedItems(
            from: overflowPasteboard,
            maximumItems: limits.maximumItems,
            rejectingOverflow: true
        ))
    }

    func testBoundedFileURLScanRejectsItemAndTypeOverflow() async {
        let target = URL(fileURLWithPath: "/tmp/target.webp")
        let validItem = NSPasteboardItem()
        XCTAssertTrue(validItem.setString(target.absoluteString, forType: .fileURL))
        let validPasteboard = PasteboardSnapshotFakePasteboard(items: [validItem])
        let validURLs = await PasteboardSnapshot.boundedFileURLs(
            from: validPasteboard,
            maximumItems: limits.maximumItems,
            maximumTypesPerItem: limits.maximumTypesPerItem,
            fileURLReader: BoundedFileURLReader(url: target)
        )
        XCTAssertEqual(validURLs, [target.standardizedFileURL])

        let overflowPasteboard = PasteboardSnapshotFakePasteboard(items: [
            validItem,
            makePasteboardSnapshotItem(text: "two"),
            makePasteboardSnapshotItem(text: "three")
        ])
        let itemOverflowURLs = await PasteboardSnapshot.boundedFileURLs(
            from: overflowPasteboard,
            maximumItems: limits.maximumItems,
            maximumTypesPerItem: limits.maximumTypesPerItem
        )
        XCTAssertNil(itemOverflowURLs)

        let typedOverflowItem = NSPasteboardItem()
        XCTAssertTrue(typedOverflowItem.setString(target.absoluteString, forType: .fileURL))
        XCTAssertTrue(typedOverflowItem.setString("metadata", forType: .string))
        XCTAssertTrue(typedOverflowItem.setData(Data(), forType: .rtf))
        let typedOverflowPasteboard = PasteboardSnapshotFakePasteboard(items: [typedOverflowItem])
        let typeOverflowURLs = await PasteboardSnapshot.boundedFileURLs(
            from: typedOverflowPasteboard,
            maximumItems: limits.maximumItems,
            maximumTypesPerItem: limits.maximumTypesPerItem
        )
        XCTAssertNil(typeOverflowURLs)
    }

    func testWebPReferenceTreatsOverLimitPasteboardAsUncertain() async {
        let target = URL(fileURLWithPath: "/tmp/target.webp")
        let first = NSPasteboardItem()
        XCTAssertTrue(first.setString(target.absoluteString, forType: .fileURL))
        var itemOverflow = [first]
        itemOverflow.append(contentsOf: (1...PasteboardSnapshotPolicy.maximumItems).map { index in
            makePasteboardSnapshotItem(text: "item-\(index)")
        })
        let itemOverflowPasteboard = PasteboardSnapshotFakePasteboard(items: itemOverflow)
        let itemOverflowReferenced = await ClipboardImageConversionPasteboardCapture.referencesFile(
            target,
            pasteboard: itemOverflowPasteboard,
            fileURLReader: BoundedFileURLReader(url: target)
        )
        XCTAssertTrue(itemOverflowReferenced)

        let typeOverflow = NSPasteboardItem()
        XCTAssertTrue(typeOverflow.setString(target.absoluteString, forType: .fileURL))
        for index in 0..<PasteboardSnapshotPolicy.maximumTypesPerItem {
            XCTAssertTrue(typeOverflow.setData(
                Data(),
                forType: NSPasteboard.PasteboardType("com.example.type-\(index)")
            ))
        }
        let typeOverflowPasteboard = PasteboardSnapshotFakePasteboard(items: [typeOverflow])
        let typeOverflowReferenced = await ClipboardImageConversionPasteboardCapture.referencesFile(
            target,
            pasteboard: typeOverflowPasteboard,
            fileURLReader: BoundedFileURLReader(url: target)
        )
        XCTAssertTrue(typeOverflowReferenced)
    }

    func testWebPCaptureTreatsItemOverflowAsUnavailable() async {
        var items = (0..<PasteboardSnapshotPolicy.maximumItems).map { index in
            makePasteboardSnapshotItem(text: "item-" + String(index))
        }
        let imageItem = NSPasteboardItem()
        XCTAssertTrue(imageItem.setData(Data([1]), forType: .png))
        items.append(imageItem)
        let pasteboard = PasteboardSnapshotFakePasteboard(items: items)

        guard case .unavailable = await ClipboardImageConversionPasteboardCapture.captureImage(
            from: pasteboard,
            payloadReader: InlinePasteboardPayloadReader()
        ) else {
            return XCTFail("Expected item-count overflow to be unavailable")
        }
    }

    func testWebPCaptureTreatsTypeOverflowAsUnavailable() async {
        let item = NSPasteboardItem()
        for index in 0..<PasteboardSnapshotPolicy.maximumTypesPerItem {
            XCTAssertTrue(item.setData(
                Data(),
                forType: NSPasteboard.PasteboardType("com.example.type-" + String(index))
            ))
        }
        XCTAssertTrue(item.setData(Data([1]), forType: .png))
        XCTAssertEqual(item.types.count, PasteboardSnapshotPolicy.maximumTypesPerItem + 1)
        XCTAssertEqual(item.types[PasteboardSnapshotPolicy.maximumTypesPerItem], .png)
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [item])

        guard case .unavailable = await ClipboardImageConversionPasteboardCapture.captureImage(
            from: pasteboard,
            payloadReader: InlinePasteboardPayloadReader()
        ) else {
            return XCTFail("Expected type-count overflow to be unavailable")
        }
    }

    func testExactFileURLRequiresOnlyTheFileURLType() async {
        let target = URL(fileURLWithPath: "/tmp/target.webp")
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(target.absoluteString, forType: .fileURL))
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [item])

        let exactURL = await PasteboardSnapshot.exactFileURL(
            from: pasteboard,
            maximumItems: limits.maximumItems,
            maximumTypesPerItem: limits.maximumTypesPerItem,
            fileURLReader: BoundedFileURLReader(url: target)
        )
        XCTAssertEqual(exactURL, target.standardizedFileURL)

        XCTAssertTrue(item.setString("metadata", forType: .string))
        let metadataExactURL = await PasteboardSnapshot.exactFileURL(
            from: pasteboard,
            maximumItems: limits.maximumItems,
            maximumTypesPerItem: limits.maximumTypesPerItem,
            fileURLReader: BoundedFileURLReader(url: target)
        )
        XCTAssertNil(metadataExactURL)
    }

    func testWebPReferenceTreatsOversizedFileURLAsUncertain() async {
        let item = NSPasteboardItem()
        let oversizedURL = String(repeating: "x", count: PasteboardSnapshot.maximumFileURLBytes + 1)
        XCTAssertTrue(item.setString(oversizedURL, forType: .fileURL))
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [item])

        let isReferenced = await ClipboardImageConversionPasteboardCapture.referencesFile(
            URL(fileURLWithPath: "/tmp/target.webp"),
            pasteboard: pasteboard,
            fileURLReader: BoundedFileURLReader(
                data: Data(repeating: 0, count: PasteboardSnapshot.maximumFileURLBytes + 1)
            )
        )
        XCTAssertTrue(isReferenced)
    }

    func testAggregateReadRejectsNegativeMaximumBytesWithoutReading() async {
        let reader = CountingPayloadReader()
        let item = makePasteboardSnapshotItem(text: "value")

        guard case .missing = await PasteboardPayloadReader.readData(
            from: [item],
            forType: .string,
            maximumBytes: -1,
            payloadReader: reader
        ) else {
            return XCTFail("Expected invalid aggregate limit to fail closed")
        }
        XCTAssertEqual(reader.invocationCount, 0)
    }

    func testAggregatePreservesCanonicalFailureResults() async {
        let item = makePasteboardSnapshotItem(text: "value")
        let failures: [PasteboardBoundedReadResult] = [.timedOut, .cancelled, .failed]

        for failure in failures {
            let result = await PasteboardPayloadReader.readData(
                from: [item],
                forType: .string,
                maximumBytes: 16,
                payloadReader: CountingPayloadReader(result: failure)
            )
            XCTAssertEqual(result, failure)
        }
    }
    func testNativePayloadReadRejectsOverLimitMaterializedData() async {
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(Data([1, 2, 3]), forType: .png))
        guard case let .tooLarge(byteCount) = await PasteboardPayloadReader.readData(
            from: item,
            forType: .png,
            maximumBytes: 2
        ) else {
            return XCTFail("Expected native item payload to honor the byte limit")
        }
        XCTAssertEqual(byteCount, 3)

        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Data([4, 5, 6]), forType: .png))
        guard case let .data(data) = await PasteboardPayloadReader.readData(
            from: pasteboard,
            forType: .png,
            maximumBytes: 3
        ) else {
            return XCTFail("Expected the default native payload reader to materialize data")
        }
        XCTAssertEqual(data, Data([4, 5, 6]))
    }
    @MainActor
    private final class BoundedFileURLReader: PasteboardFileURLReading {
        private let data: Data

        init(url: URL) {
            data = Data(url.absoluteString.utf8)
        }

        init(data: Data) {
            self.data = data
        }

        func readFileURLData(
            from _: NSPasteboardItem,
            maximumBytes: Int,
            timeout: TimeInterval
        ) async -> PasteboardFileURLReadResult {
            guard !Task.isCancelled else { return .cancelled }
            guard maximumBytes >= 0, timeout.isFinite, timeout >= 0 else {
                return .unavailable
            }
            guard data.count <= maximumBytes else {
                return .tooLarge(byteCount: data.count)
            }
            return .data(data)
        }
    }

    @MainActor
    private final class CountingPayloadReader: PasteboardPayloadReading {
        private(set) var invocationCount = 0
        private let result: PasteboardPayloadReader.Result

        init(result: PasteboardPayloadReader.Result = .data(Data([1]))) {
            self.result = result
        }

        func readData(
            from _: NSPasteboardItem,
            forType _: NSPasteboard.PasteboardType,
            maximumBytes _: Int
        ) async -> PasteboardPayloadReader.Result {
            invocationCount += 1
            return result
        }
    }
}
