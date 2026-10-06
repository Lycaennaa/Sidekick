import AppKit
import XCTest

@MainActor
final class ClipboardPayloadTests: XCTestCase {
    func testFileRepresentationBeatsImageAndText() async {
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: "/missing/report.txt").absoluteString, forType: .fileURL)
        item.setData(Data([0x00]), forType: .png)
        item.setString("fallback text", forType: .string)

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [item],
            generation: 1,
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader()
        )

        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(model.presentationStyle, .files)
        XCTAssertEqual(model.summary, "Copied report.txt")
        XCTAssertNil(imageEnrichment(from: analysis.classification))

    }
    func testImageBeatsTextAndSmallImageRequestsEnrichment() async {
        let item = NSPasteboardItem()
        item.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        item.setString("fallback text", forType: .string)

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [item],
            generation: 7,
            payloadReader: InlinePasteboardPayloadReader()
        )

        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(model.presentationStyle, .image)
        XCTAssertEqual(model.summary, "Copied image")
        XCTAssertEqual(model.footer, byteCountLabel(4))
        XCTAssertEqual(imageEnrichment(from: analysis.classification)?.generation, 7)
        XCTAssertEqual(
            imageEnrichment(from: analysis.classification)?.typeIdentifier,
            NSPasteboard.PasteboardType.png.rawValue
        )
    }

    func testScreenshotImageToastUsesRegisteredDynamicRange() async {
        let ranges: [ClipboardScreenshotDynamicRange] = [.sdr, .hdr]
        for (index, range) in ranges.enumerated() {
            let item = NSPasteboardItem()
            item.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
            let analysis = await ClipboardPayloadClassifier.analyze(
                items: [item],
                generation: UInt64(index),
                payloadReader: InlinePasteboardPayloadReader(),
                screenshotDynamicRange: range
            )
            let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
            XCTAssertEqual(model.summary, "Copied image • \(range.toastLabel)")
        }
    }

    func testPasteboardMarkerCannotClaimScreenshotDynamicRange() async {
        let item = NSPasteboardItem()
        item.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        item.setString(
            "hdr",
            forType: NSPasteboard.PasteboardType("com.sidekick.screenshot.dynamic-range")
        )

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [item],
            generation: 1,
            payloadReader: InlinePasteboardPayloadReader()
        )
        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)

        XCTAssertEqual(model.summary, "Copied image")
    }

    func testNativePayloadUsesDefaultReader() async {
        let item = NSPasteboardItem()
        item.setString("native clipboard text", forType: .string)

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [item],
            generation: 8
        )

        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(model.presentationStyle, .text)
        XCTAssertEqual(model.summary, "native clipboard text")
        XCTAssertNil(model.detail)
    }

    func testTextMetricsUseCapturedTextAndTokenizer() async throws {
        let item = NSPasteboardItem()
        item.setString("hello world", forType: .string)
        let loader = ControlledTokenizerLoader(encoder: try makeTestO200kBase())
        await loader.state.release()
        let tokenizer = ClipboardTokenizer(loader: loader)

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [item],
            generation: 9,
            payloadReader: InlinePasteboardPayloadReader(),
            tokenizer: tokenizer
        )

        XCTAssertEqual(
            analysis.textMetrics,
            ClipboardTextMetrics(wordCount: 2, characterCount: 11, tokenCount: 11)
        )
        let model = ClipboardPayloadPresentation.toastModel(
            from: analysis.classification,
            textMetrics: analysis.textMetrics
        )
        XCTAssertEqual(model.footer, "2 words • 11 characters • 11 tokens")
        await tokenizer.shutdown()
    }

    func testMarkdownMetricsFooterUsesCopyToastFormat() {
        let before = ClipboardTextMetrics(wordCount: 2, characterCount: 11, tokenCount: 11)
        let after = ClipboardTextMetrics(wordCount: 2, characterCount: 9, tokenCount: 9)
        let result = ClipboardMarkdownController.Result.cleaned(
            changeCount: 12,
            metrics: ClipboardMarkdownMetrics(before: before, after: after)
        )

        let content = ClipboardMarkdownPresentation.toastContent(for: result)

        XCTAssertEqual(
            content?.footer,
            "Before: 2 words • 11 characters • 11 tokens\nAfter: 2 words • 9 characters • 9 tokens"
        )
        XCTAssertEqual(content?.message, "Cleaned Markdown")
        XCTAssertEqual(content?.acknowledgedChangeCount, 12)
    }
    func testTextNormalizesWhitespaceAndBoundsWholeGraphemes() {
        let family = "👨‍👩‍👧‍👦"
        let input = "  hello\n\tworld  "
            + String(repeating: family, count: ClipboardPayloadClassifier.maximumPreviewCharacters + 1)
            + "  "
        let preview = ClipboardPayloadClassifier.normalizedPreview(input)

        XCTAssertTrue(preview.hasPrefix("hello world"))
        XCTAssertTrue(preview.hasSuffix("…"))
        XCTAssertTrue(String(preview.dropLast()).hasSuffix(family))
        XCTAssertLessThanOrEqual(
            preview.unicodeScalars.count,
            ClipboardPayloadClassifier.maximumPreviewUnicodeScalars + 1
        )
    }

    func testTextAtBoundaryHasNoUnnecessaryEllipsis() {
        let input = String(repeating: "é", count: ClipboardPayloadClassifier.maximumPreviewCharacters)

        XCTAssertEqual(ClipboardPayloadClassifier.normalizedPreview(input), input)
    }

    func testTextPreviewUsesExpandedToastCapacity() {
        let input = String(repeating: "x", count: 1_000)

        XCTAssertEqual(ClipboardPayloadClassifier.normalizedPreview(input), input)
    }

    func testTextPreviewRejectsOversizedGraphemeCluster() {
        let input = "a" + String(
            repeating: "\u{301}",
            count: ClipboardPayloadClassifier.maximumPreviewScalarsPerCharacter
        )

        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(ClipboardPayloadClassifier.normalizedPreview(input), "")
    }

    func testEmptyNormalizedTextUsesGenericTextLabel() async {
        let item = NSPasteboardItem()
        item.setString(" \n\t ", forType: .string)

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [item],
            generation: 1,
            payloadReader: InlinePasteboardPayloadReader()
        )

        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(model.presentationStyle, .text)
        XCTAssertEqual(model.summary, "Copied text")
    }

    func testTransientAutogeneratedAndConcealedItemsSuppressToasts() {
        for type in ClipboardPayloadClassifier.suppressedToastTypes {
            let item = NSPasteboardItem()
            item.setString("selected text", forType: .string)
            item.setData(Data(), forType: type)

            XCTAssertTrue(ClipboardPayloadClassifier.shouldSuppressToast(items: [item]), type.rawValue)
        }

        let regularItem = NSPasteboardItem()
        regularItem.setString("copied text", forType: .string)
        XCTAssertFalse(ClipboardPayloadClassifier.shouldSuppressToast(items: [regularItem]))
    }

    func testTransientMarkerLookupFindsMarkerAfterClassifierTypeBound() {
        let item = NSPasteboardItem()
        for index in 0..<ClipboardPayloadClassifier.maximumTypeEntries {
            item.setData(Data(), forType: NSPasteboard.PasteboardType("com.example.raw-\(index)"))
        }
        item.setData(
            Data(),
            forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        )

        XCTAssertTrue(ClipboardPayloadClassifier.shouldSuppressToast(items: [item]))
    }

}

extension ClipboardPayloadTests {
    func testTextFingerprintDetectsRestoredAndChangedClipboardText() async throws {
        let original = NSPasteboardItem()
        original.setString("original clipboard", forType: .string)
        let restored = NSPasteboardItem()
        restored.setString("original clipboard", forType: .string)
        let changed = NSPasteboardItem()
        changed.setString("new clipboard", forType: .string)

        let originalFingerprintValue = await ClipboardPayloadClassifier.textFingerprint(
            items: [original],
            payloadReader: InlinePasteboardPayloadReader()
        )
        let originalFingerprint = try XCTUnwrap(originalFingerprintValue)
        let restoredFingerprint = await ClipboardPayloadClassifier.textFingerprint(
            items: [restored],
            payloadReader: InlinePasteboardPayloadReader()
        )
        let changedFingerprint = await ClipboardPayloadClassifier.textFingerprint(
            items: [changed],
            payloadReader: InlinePasteboardPayloadReader()
        )
        XCTAssertEqual(originalFingerprint, restoredFingerprint)
        XCTAssertNotEqual(originalFingerprint, changedFingerprint)
    }

    func testTextFingerprintIncludesAvailableRepresentations() async throws {
        let plain = NSPasteboardItem()
        plain.setString("same text", forType: .string)
        let rich = NSPasteboardItem()
        rich.setString("same text", forType: .string)
        rich.setData(Data("{\\rtf1 same text}".utf8), forType: .rtf)

        let plainFingerprintValue = await ClipboardPayloadClassifier.textFingerprint(
            items: [plain],
            payloadReader: InlinePasteboardPayloadReader()
        )
        let plainFingerprint = try XCTUnwrap(plainFingerprintValue)
        let richFingerprintValue = await ClipboardPayloadClassifier.textFingerprint(
            items: [rich],
            payloadReader: InlinePasteboardPayloadReader()
        )
        let richFingerprint = try XCTUnwrap(richFingerprintValue)
        XCTAssertNotEqual(plainFingerprint, richFingerprint)
    }

    func testTextFingerprintSupportsOversizedTextWithinSourceLimit() async throws {
        let text = String(repeating: "x", count: ClipboardPayloadClassifier.maximumTextBytes + 1)
        let original = NSPasteboardItem()
        original.setString(text, forType: .string)
        let restored = NSPasteboardItem()
        restored.setString(text, forType: .string)

        let fingerprintValue = await ClipboardPayloadClassifier.textFingerprint(
            items: [original],
            payloadReader: InlinePasteboardPayloadReader()
        )
        let fingerprint = try XCTUnwrap(fingerprintValue)
        let restoredFingerprint = await ClipboardPayloadClassifier.textFingerprint(
            items: [restored],
            payloadReader: InlinePasteboardPayloadReader()
        )
        XCTAssertGreaterThan(fingerprint.byteCount, ClipboardPayloadClassifier.maximumTextBytes)
        XCTAssertEqual(fingerprint, restoredFingerprint)
    }

    func testOversizedTextFingerprintIncludesMiddleBytes() async throws {
        let edge = Data(repeating: 0x61, count: 600_000)
        let first = NSPasteboardItem()
        first.setData(edge + Data([0x62]) + edge, forType: .string)
        let second = NSPasteboardItem()
        second.setData(edge + Data([0x63]) + edge, forType: .string)

        let firstFingerprintValue = await ClipboardPayloadClassifier.textFingerprint(
            items: [first],
            payloadReader: InlinePasteboardPayloadReader()
        )
        let firstFingerprint = try XCTUnwrap(firstFingerprintValue)
        let secondFingerprintValue = await ClipboardPayloadClassifier.textFingerprint(
            items: [second],
            payloadReader: InlinePasteboardPayloadReader()
        )
        let secondFingerprint = try XCTUnwrap(secondFingerprintValue)
        XCTAssertNotEqual(firstFingerprint, secondFingerprint)
    }

    func testOnlyKnownTransientRestorationSuppressesMatchingText() async throws {
        let original = NSPasteboardItem()
        original.setString("same text", forType: .string)
        let changed = NSPasteboardItem()
        changed.setString("different text", forType: .string)
        let baselineValue = await ClipboardPayloadClassifier.textFingerprint(
            items: [original],
            payloadReader: InlinePasteboardPayloadReader()
        )
        let baseline = try XCTUnwrap(baselineValue)
        let changedFingerprint = await ClipboardPayloadClassifier.textFingerprint(
            items: [changed],
            payloadReader: InlinePasteboardPayloadReader()
        )

        XCTAssertFalse(
            shouldSuppressTransientTextRestore(
                isAwaitingTransientResolution: false,
                baseline: baseline,
                current: baseline
            )
        )
        XCTAssertTrue(
            shouldSuppressTransientTextRestore(
                isAwaitingTransientResolution: true,
                baseline: baseline,
                current: baseline
            )
        )
        XCTAssertFalse(
            shouldSuppressTransientTextRestore(
                isAwaitingTransientResolution: true,
                baseline: baseline,
                current: changedFingerprint
            )
        )
    }

    func testTransientTrackingRecognizesMarkersAndMultipleWritesBetweenPolls() {
        XCTAssertTrue(
            shouldTrackTransientPasteboardChange(
                previousChangeCount: 10,
                currentChangeCount: 11,
                containsTransientMarker: true
            )
        )
        XCTAssertTrue(
            shouldTrackTransientPasteboardChange(
                previousChangeCount: 10,
                currentChangeCount: 12,
                containsTransientMarker: false
            )
        )
        XCTAssertFalse(
            shouldTrackTransientPasteboardChange(
                previousChangeCount: 10,
                currentChangeCount: 11,
                containsTransientMarker: false
            )
        )
    }

    func testSourceAttributionRejectsApplicationSwitchDuringPollingGap() {
        XCTAssertNil(
            attributedSourceApplication(
                previous: "Safari",
                current: "Finder",
                applicationChanged: true
            )
        )
        XCTAssertNil(
            attributedSourceApplication(
                previous: "Safari",
                current: "Safari",
                applicationChanged: true
            )
        )
        XCTAssertEqual(
            attributedSourceApplication(
                previous: "Safari",
                current: "Safari",
                applicationChanged: false
            ),
            "Safari"
        )
    }

    func testOversizeTextUsesSizeOnlyModel() async {
        let item = NSPasteboardItem()
        item.setData(
            Data(repeating: 0x78, count: ClipboardPayloadClassifier.maximumTextBytes + 1),
            forType: .string
        )

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [item],
            generation: 1,
            payloadReader: InlinePasteboardPayloadReader()
        )

        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(model.presentationStyle, .text)
        XCTAssertTrue(model.summary.hasPrefix("Copied text • "))
        XCTAssertFalse(model.summary.contains(String(repeating: "x", count: 20)))
    }

    func testOversizedImageDoesNotRequestEnrichment() async {
        let item = NSPasteboardItem()
        item.setData(
            Data(repeating: 0x00, count: ClipboardPayloadClassifier.maximumImageBytes + 1),
            forType: .png
        )

        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [item],
            generation: 2,
            payloadReader: InlinePasteboardPayloadReader()
        )

        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(model.presentationStyle, .image)
        XCTAssertNil(imageEnrichment(from: analysis.classification))
        XCTAssertNotNil(model.footer)
    }

    private func imageEnrichment(
        from classification: ClipboardPayloadClassification
    ) -> ClipboardImageEnrichmentRequest? {
        switch classification {
        case let .files(_, _, _, _, _, _, request):
            return request
        case let .image(_, _, request, _):
            return request
        case .text, .generic, .unavailable:
            return nil
        }
    }

}
