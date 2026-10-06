import AppKit
import XCTest

@MainActor
final class ClipboardPayloadFileTests: XCTestCase {
    func testMultipleFilesUseFirstNameAndTotalCount() async {
        let first = fileItem("/missing/one.txt")
        let second = fileItem("/missing/two.txt")
        let third = fileItem("/missing/three.txt")

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [first, second, third],
            generation: 1,
            fileURLReader: InlinePasteboardFileURLReader()
        )

        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(model.presentationStyle, .files)
        XCTAssertEqual(model.summary, "Copied one.txt + 2 more")
        XCTAssertEqual(model.detail, "3 files")
    }
    func testFileClassificationMarksUninspectedSuffixAsUncertain() async {
        let first = fileItem("/missing/one.txt")
        let reader = ClassifierFileURLReader(
            responses: [.data(Data(URL(fileURLWithPath: "/missing/one.txt").absoluteString.utf8))]
        )

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [first],
            generation: 1,
            totalItemCount: ClipboardPayloadClassifier.maximumFileItems + 1,
            fileURLReader: reader
        )

        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(model.presentationStyle, .files)
        XCTAssertEqual(model.summary, "Copied one.txt + more")
        XCTAssertEqual(model.detail, "More files not inspected")
        XCTAssertEqual(reader.readCount, 1)
    }

    func testFileScanStopsAtTenThousandAndUsesBoundedLabel() {
        let classification: ClipboardPayloadClassification = .files(
            generation: 1,
            firstName: "one.txt",
            count: ClipboardPayloadClassifier.maximumFileItems,
            overflow: true,
            uncertain: false,
            representativeFileURL: nil,
            imageEnrichment: nil
        )
        let model = ClipboardPayloadPresentation.toastModel(from: classification)

        XCTAssertEqual(ClipboardPayloadClassifier.maximumFileItems, 10_000)
        XCTAssertEqual(model.summary, "Copied one.txt + 9,999+ more")
        XCTAssertEqual(model.detail, "10,000+ files")

    }
    func testFileSummaryBoundsOversizedName() {
        let classification: ClipboardPayloadClassification = .files(
            generation: 1,
            firstName: String(
                repeating: "x",
                count: ClipboardPayloadClassifier.maximumPreviewCharacters + 1
            ),
            count: 1,
            overflow: false,
            uncertain: false,
            representativeFileURL: nil,
            imageEnrichment: nil
        )
        let summary = ClipboardPayloadPresentation.toastModel(from: classification).summary

        XCTAssertTrue(summary.hasPrefix("Copied "))
        XCTAssertTrue(summary.hasSuffix("…"))
        XCTAssertLessThanOrEqual(
            summary.count,
            "Copied ".count + ClipboardPayloadClassifier.maximumPreviewCharacters + 1
        )
    }

    func testMalformedFileURLDegradesSafely() async {
        let item = NSPasteboardItem()
        item.setString("%%%", forType: .fileURL)

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [item],
            generation: 1,
            fileURLReader: InlinePasteboardFileURLReader()
        )

        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(model.presentationStyle, .files)
        XCTAssertEqual(model.summary, "Copied file")
        XCTAssertNotNil(model.icon)
    }

    func testFileReadFailuresBecomeUnavailableAtDomainBoundary() async {
        let item = fileItem("/missing/file.txt")
        let failures: [PasteboardBoundedReadResult] = [.timedOut, .cancelled, .failed]

        for failure in failures {
            let analysis = await ClipboardPayloadClassifier.analyze(
                items: [item],
                generation: 1,
                fileURLReader: ClassifierFileURLReader(responses: [failure])
            )

            XCTAssertEqual(analysis.classification, .unavailable(generation: 1))
        }
    }
    func testRemoteURLOnlyRepresentationFallsBackToText() async {
        let item = NSPasteboardItem()
        item.setString("https://example.com/file.txt", forType: .URL)

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [item],
            generation: 1,
            payloadReader: InlinePasteboardPayloadReader()
        )

        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(model.presentationStyle, .text)
        XCTAssertEqual(model.summary, "https://example.com/file.txt")
    }

    func testRemoteHostFileURLIsNotClassifiedAsLocalFile() async {
        let item = NSPasteboardItem()
        item.setString("file://example.com/shared/report.txt", forType: .fileURL)

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [item],
            generation: 1,
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader()
        )

        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(model.presentationStyle, .text)
        XCTAssertEqual(model.summary, "file://example.com/shared/report.txt")
    }

    func testSchemeRelativeRemoteFileURLIsNotClassifiedAsLocalFile() async {
        let item = NSPasteboardItem()
        item.setString("//example.com/shared/report.txt", forType: .fileURL)

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [item],
            generation: 1,
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader()
        )

        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(model.presentationStyle, .text)
        XCTAssertEqual(model.summary, "//example.com/shared/report.txt")
    }
    func testLocalFileURLPolicyAcceptsOnlyLocalHosts() {
        XCTAssertTrue(isLocalFileURL(URL(fileURLWithPath: "/local/path/image.png")))
        XCTAssertTrue(isLocalFileURL(URL(string: "file://localhost/local/path/image.png")!))
        XCTAssertFalse(isLocalFileURL(URL(string: "file://example.com/tmp/image.png")!))
        XCTAssertFalse(isLocalFileURL(URL(string: "https://example.com/image.png")!))
    }

    func testFriendlyGenericTypeAndRawTypeFallback() async {
        let richText = NSPasteboardItem()
        richText.setData(Data(), forType: .rtf)
        let friendlyAnalysis = await ClipboardPayloadClassifier.analyze(items: [richText], generation: 1)

        let model = ClipboardPayloadPresentation.toastModel(from: friendlyAnalysis.classification)
        XCTAssertEqual(model.presentationStyle, .generic)
        XCTAssertNotEqual(model.summary, "Copied item")
        XCTAssertFalse(model.summary.contains(NSPasteboard.PasteboardType.rtf.rawValue))

        let raw = NSPasteboardItem()
        raw.setData(Data(), forType: NSPasteboard.PasteboardType("com.example.private-payload"))
        let genericAnalysis = await ClipboardPayloadClassifier.analyze(items: [raw], generation: 2)

        XCTAssertEqual(
            ClipboardPayloadPresentation.toastModel(from: genericAnalysis.classification).summary,
            "Copied item"
        )
    }

    func testImageDetectionHonorsSixtyFourTypeScanBound() async {
        let rawItems = (0..<ClipboardPayloadClassifier.maximumTypeEntries).map { index in
            let item = NSPasteboardItem()
            item.setData(Data(), forType: NSPasteboard.PasteboardType("com.example.raw-\(index)"))
            return item
        }
        let image = NSPasteboardItem()
        image.setData(Data([0x00]), forType: .png)

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: rawItems + [image],
            generation: 1
        )

        XCTAssertEqual(
            ClipboardPayloadPresentation.toastModel(from: analysis.classification).summary,
            "Copied item"
        )
    }

    func testPresentationMapperBuildsUIAtBoundaryAndKeepsFacts() {
        let fileURL = URL(fileURLWithPath: "/missing/image.png")
        let classification: ClipboardPayloadClassification = .files(
            generation: 11,
            firstName: "image.png",
            count: 2,
            overflow: false,
            uncertain: false,
            representativeFileURL: fileURL,
            imageEnrichment: nil
        )

        let model = ClipboardPayloadPresentation.toastModel(from: classification)

        XCTAssertEqual(model.generation, 11)
        XCTAssertEqual(model.presentationStyle, .files)
        XCTAssertEqual(model.summary, "Copied image.png + 1 more")
        XCTAssertEqual(model.detail, "2 files")
        XCTAssertNil(model.footer)
        XCTAssertNotNil(model.icon)

        let textClassification: ClipboardPayloadClassification = .text(
            generation: 12,
            preview: nil,
            oversizedByteCount: nil
        )
        let textModel = ClipboardPayloadPresentation.toastModel(from: textClassification)
        XCTAssertEqual(textModel.presentationStyle, .text)
        XCTAssertEqual(textModel.summary, "Copied text")
        XCTAssertNil(textModel.footer)
        XCTAssertNotNil(textModel.icon)

    }

    func testFileClassificationStopsAtAggregateURLReadBudget() async {
        let items = (0...ClipboardPayloadClassifier.maximumFileURLReadCount)
            .map { fileItem("/missing/file-\($0).txt") }
        let reader = ClassifierFileURLReader()

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: items,
            generation: 1,
            fileURLReader: reader
        )

        XCTAssertEqual(reader.readCount, ClipboardPayloadClassifier.maximumFileURLReadCount)
        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(model.presentationStyle, .files)
        XCTAssertEqual(model.detail, "More files not inspected")
    }

    func testFileClassificationStopsWhenURLByteBudgetIsExhausted() async {
        let perURLBytes = PasteboardSnapshot.maximumFileURLBytes
        let expectedReads = ClipboardPayloadClassifier.maximumFileURLReadBytes / perURLBytes
        let items = (0...expectedReads)
            .map { fileItem("/missing/file-\($0).txt") }
        let chunk = Data(repeating: 0, count: perURLBytes)
        let reader = ClassifierFileURLReader(
            responses: Array(
                repeating: PasteboardFileURLReadResult.data(chunk),
                count: expectedReads
            )
        )

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: items,
            generation: 1,
            fileURLReader: reader
        )

        XCTAssertEqual(reader.readCount, expectedReads)
        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(model.presentationStyle, .files)
        XCTAssertEqual(model.detail, "More files not inspected")
    }

    private func fileItem(_ path: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        return item
    }
}
@MainActor
private final class ClassifierFileURLReader: PasteboardFileURLReading {
    private var responses: [PasteboardFileURLReadResult]
    private(set) var readCount = 0

    init(responses: [PasteboardFileURLReadResult] = []) {
        self.responses = responses
    }

    func readFileURLData(
        from item: NSPasteboardItem,
        maximumBytes: Int,
        timeout: TimeInterval
    ) async -> PasteboardFileURLReadResult {
        readCount += 1
        if !responses.isEmpty {
            return responses.removeFirst()
        }
        return .data(Data(URL(fileURLWithPath: "/missing/file-\(readCount).txt").absoluteString.utf8))
    }
}
