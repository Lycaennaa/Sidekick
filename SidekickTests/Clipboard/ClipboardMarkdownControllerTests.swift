import AppKit
import XCTest

final class ClipboardMarkdownControllerTests: XCTestCase {

    @MainActor
    func testCleanClipboardReplacesMarkdownWithPlainText() async {
        let pasteboard = makePasteboard()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("**Bold** [link](https://example.com)", forType: .string))
        XCTAssertTrue(item.setString("<b>rich</b>", forType: .html))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let controller = ClipboardMarkdownController(
            pasteboard: pasteboard,
            payloadReader: InlinePasteboardPayloadReader()
        )

        let result = await controller.cleanClipboard()

        guard case let .cleaned(changeCount, _) = result else {
            return XCTFail("Expected cleaned result, got \(result)")
        }
        XCTAssertEqual(changeCount, pasteboard.changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "Bold link")
        XCTAssertNil(pasteboard.data(forType: .html))
    }

    @MainActor
    func testCleanClipboardReportsMetricsBeforeAndAfter() async throws {
        let pasteboard = makePasteboard()
        let markdown = "**hello** world"
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(markdown, forType: .string))
        let loader = ControlledTokenizerLoader(encoder: try makeTestO200kBase())
        await loader.state.release()
        let tokenizer = ClipboardTokenizer(loader: loader)
        let controller = ClipboardMarkdownController(
            pasteboard: pasteboard,
            payloadReader: InlinePasteboardPayloadReader(),
            tokenizer: tokenizer
        )

        let result = await controller.cleanClipboard()

        guard case let .cleaned(changeCount, metrics) = result else {
            return XCTFail("Expected cleaned result, got \(result)")
        }
        XCTAssertEqual(changeCount, pasteboard.changeCount)
        XCTAssertEqual(
            metrics.before,
            ClipboardTextMetrics(wordCount: 2, characterCount: 15, tokenCount: 15)
        )
        XCTAssertEqual(
            metrics.after,
            ClipboardTextMetrics(wordCount: 2, characterCount: 11, tokenCount: 11)
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "hello world")
        await tokenizer.shutdown()
    }

    @MainActor
    func testCleanClipboardAllowsReplacementAboveInputLimit() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("input", forType: .string))
        let replacement = String(
            repeating: "x",
            count: ClipboardMarkdownController.maximumInputBytes + 1
        )
        let tokenizer = ClipboardTokenizer()
        await tokenizer.shutdown()
        let controller = ClipboardMarkdownController(
            pasteboard: pasteboard,
            cleaner: { _ in replacement },
            payloadReader: InlinePasteboardPayloadReader(),
            tokenizer: tokenizer
        )

        let result = await controller.cleanClipboard()

        guard case .cleaned = result else {
            return XCTFail("Expected cleaned result, got \(result)")
        }
        XCTAssertEqual(pasteboard.string(forType: .string), replacement)
    }
    @MainActor
    func testCleanerRunsOffMainActorThroughOwnedBackgroundBoundary() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("plain clipboard text", forType: .string))
        let execution = MarkdownCleanerExecutionState()
        let controller = ClipboardMarkdownController(
            pasteboard: pasteboard,
            cleaner: { markdown in
                await execution.record(isMainThread: isMainThreadSynchronously())
                return markdown
            },
            payloadReader: InlinePasteboardPayloadReader()
        )

        let result = await controller.cleanClipboard()

        guard case .cleaned = result else {
            return XCTFail("Expected cleaned result, got \(result)")
        }
        let ranOnMainThread = await execution.wasMainThread()
        XCTAssertEqual(ranOnMainThread, false)
    }

    @MainActor
    func testDefaultCleaningCancellationReturnsCancelled() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        let original = "plain clipboard text"
        XCTAssertTrue(pasteboard.setString(original, forType: .string))
        let controller = ClipboardMarkdownController(
            pasteboard: pasteboard,
            payloadReader: InlinePasteboardPayloadReader()
        )
        let task = Task { @MainActor in
            await controller.cleanClipboard()
        }

        task.cancel()

        let result = await task.value
        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(pasteboard.string(forType: .string), original)
    }

    @MainActor
    func testCleanClipboardDecodesUTF16TextUsingCanonicalDecoder() async {
        let pasteboard = makePasteboard()
        let markdown = "**UTF-16** [link](https://example.com)"
        let item = NSPasteboardItem()
        guard let data = markdown.data(using: .utf16) else {
            return XCTFail("Unable to encode UTF-16 test payload")
        }
        XCTAssertEqual(PasteboardPayloadReader.string(from: data), markdown)
        XCTAssertTrue(item.setData(data, forType: .string))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let controller = ClipboardMarkdownController(
            pasteboard: pasteboard,
            payloadReader: InlinePasteboardPayloadReader()
        )

        let result = await controller.cleanClipboard()

        guard case .cleaned = result else {
            return XCTFail("Expected cleaned result, got \(result)")
        }
        let installedText = pasteboard.items.first?.data(forType: .string)
            .flatMap(PasteboardPayloadReader.string(from:))
        XCTAssertEqual(installedText, "UTF-16 link")
    }

    @MainActor
    func testCleanClipboardReadsAllBoundedTextItems() async {
        let pasteboard = makePasteboard()
        let items = ["first", "second"].map { value in
            let item = NSPasteboardItem()
            XCTAssertTrue(item.setString(value, forType: .string))
            return item
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))
        let receivedText = MarkdownTextCapture()
        let controller = ClipboardMarkdownController(
            pasteboard: pasteboard,
            cleaner: { markdown in
                await receivedText.record(markdown)
                return "cleaned"
            },
            payloadReader: InlinePasteboardPayloadReader()
        )

        let result = await controller.cleanClipboard()

        guard case .cleaned = result else {
            return XCTFail("Expected cleaned result, got \(result)")
        }
        let capturedText = await receivedText.value()
        XCTAssertEqual(capturedText, "first\nsecond")
        XCTAssertEqual(pasteboard.string(forType: .string), "cleaned")
    }

    @MainActor
    func testOverLimitItemCountDoesNotInvokeCleaner() async {
        let pasteboard = makePasteboard()
        let items = (0...PasteboardSnapshot.defaultMaximumItems).map { index in
            let item = NSPasteboardItem()
            XCTAssertTrue(item.setString("item \(index)", forType: .string))
            return item
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))
        let originalChangeCount = pasteboard.changeCount
        let controller = ClipboardMarkdownController(
            pasteboard: pasteboard,
            cleaner: { _ in
                XCTFail("Cleaner should not run for an over-limit pasteboard")
                return ""
            },
            payloadReader: InlinePasteboardPayloadReader()
        )

        let result = await controller.cleanClipboard()

        XCTAssertEqual(result, .tooLarge)
        XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
    }

    @MainActor
    func testNativePayloadUsesDefaultReaderAndCleansClipboard() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("native markdown", forType: .string))
        let originalChangeCount = pasteboard.changeCount
        let controller = ClipboardMarkdownController(pasteboard: pasteboard)

        let result = await controller.cleanClipboard()

        guard case let .cleaned(changeCount, _) = result else {
            return XCTFail("Expected native payload to be cleaned, got \(result)")
        }
        XCTAssertEqual(changeCount, pasteboard.changeCount)
        XCTAssertGreaterThan(changeCount, originalChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "native markdown")
    }
}

extension ClipboardMarkdownControllerTests {
    @MainActor
    func testDefaultProductionDependenciesCleanNamedPasteboard() async {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipboardMarkdownIntegration-\(UUID().uuidString)")
        )
        defer { pasteboard.clearContents() }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(
            "**Bold** [link](https://example.com)",
            forType: .string
        ))
        let originalChangeCount = pasteboard.changeCount
        let controller = ClipboardMarkdownController(pasteboard: pasteboard)

        let result = await controller.cleanClipboard()

        guard case let .cleaned(changeCount, _) = result else {
            return XCTFail("Expected default cleaning success, got \(result)")
        }
        XCTAssertEqual(changeCount, pasteboard.changeCount)
        XCTAssertGreaterThan(changeCount, originalChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "Bold link")
    }

    @MainActor
    func testNoTextLeavesClipboardUnchanged() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setData(Data([0, 1, 2]), forType: .png)
        let originalChangeCount = pasteboard.changeCount
        let controller = ClipboardMarkdownController(
            pasteboard: pasteboard,
            payloadReader: InlinePasteboardPayloadReader()
        )

        let result = await controller.cleanClipboard()
        XCTAssertEqual(result, .noText)
        XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
        XCTAssertEqual(pasteboard.data(forType: .png), Data([0, 1, 2]))
    }

    @MainActor
    func testOversizedTextLeavesClipboardUnchanged() async {
        let pasteboard = makePasteboard()
        let original = String(repeating: "a", count: ClipboardMarkdownController.maximumInputBytes + 1)
        pasteboard.clearContents()
        pasteboard.setString(original, forType: .string)
        let originalChangeCount = pasteboard.changeCount
        let controller = ClipboardMarkdownController(
            pasteboard: pasteboard,
            payloadReader: InlinePasteboardPayloadReader()
        )

        let result = await controller.cleanClipboard()
        XCTAssertEqual(result, .tooLarge)
        XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), original)
    }

    @MainActor
    func testClipboardChangeDuringCleaningDoesNotOverwriteNewContent() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("**old**", forType: .string)
        let updatePasteboard: @MainActor @Sendable () -> Void = {
            pasteboard.clearContents()
            pasteboard.setString("new content", forType: .string)
        }
        let controller = ClipboardMarkdownController(
            pasteboard: pasteboard,
            cleaner: { markdown in
                await updatePasteboard()
                return markdown
            },
            payloadReader: InlinePasteboardPayloadReader()
        )

        let result = await controller.cleanClipboard()
        XCTAssertEqual(result, .stale)
        XCTAssertEqual(pasteboard.string(forType: .string), "new content")
    }

    @MainActor
    func testParserFailureLeavesClipboardUnchanged() async {
        struct TestError: Error {}
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("**original**", forType: .string)
        let originalChangeCount = pasteboard.changeCount
        let controller = ClipboardMarkdownController(
            pasteboard: pasteboard,
            cleaner: { _ in
                throw TestError()
            },
            payloadReader: InlinePasteboardPayloadReader()
        )
        let result = await controller.cleanClipboard()
        XCTAssertEqual(result, .failed)
        XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "**original**")
    }

    @MainActor
    func testLatestCleaningRequestPublishesOnlyLatestResult() async {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("**original**", forType: .string)
        let firstCleanerStarted = expectation(description: "First cleaner started")
        let secondCleaningCompleted = expectation(description: "Second cleaning completed")
        let gate = AsyncGate()
        let cleanerCallCounter = MarkdownCleanerCallCounter()
        let controller = ClipboardMarkdownController(
            pasteboard: pasteboard,
            cleaner: { markdown in
                let call = await cleanerCallCounter.next()
                if call == 1 {
                    firstCleanerStarted.fulfill()
                    await gate.wait()
                }
                return markdown
            },
            payloadReader: InlinePasteboardPayloadReader()
        )
        var results: [ClipboardMarkdownController.Result] = []

        controller.requestCleaning { result in
            results.append(result)
            if case .cleaned = result {
                secondCleaningCompleted.fulfill()
            }
        }
        await fulfillment(of: [firstCleanerStarted], timeout: 1)

        controller.requestCleaning { result in
            results.append(result)
            if case .cleaned = result {
                secondCleaningCompleted.fulfill()
            }
        }
        await fulfillment(of: [secondCleaningCompleted], timeout: 1)
        await gate.open()
        for _ in 0..<32 {
            await Task.yield()
        }

        guard results.count == 1,
              case let .cleaned(changeCount, metrics) = results[0] else {
            return XCTFail("Expected one cleaned result, got \(results)")
        }
        XCTAssertEqual(changeCount, pasteboard.changeCount)
        XCTAssertNotNil(metrics.before)
        XCTAssertNotNil(metrics.after)
        XCTAssertEqual(pasteboard.string(forType: .string), "**original**")
        controller.terminate()
    }

    @MainActor
    func testCancellingOwnedCleaningSuppressesCompletion() async throws {
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        pasteboard.setString("**original**", forType: .string)
        let cleanerStarted = expectation(description: "Cleaner started")
        let gate = AsyncGate()
        let loader = ControlledTokenizerLoader(encoder: try makeTestO200kBase())
        await loader.state.release()
        let tokenizer = ClipboardTokenizer(loader: loader)
        try await tokenizer.preload()
        let controller = ClipboardMarkdownController(
            pasteboard: pasteboard,
            cleaner: { markdown in
                cleanerStarted.fulfill()
                await gate.wait()
                return markdown
            },
            payloadReader: InlinePasteboardPayloadReader(),
            tokenizer: tokenizer
        )
        var results: [ClipboardMarkdownController.Result] = []

        controller.requestCleaning { results.append($0) }
        await fulfillment(of: [cleanerStarted], timeout: 1)
        controller.cancelPendingCleaning()
        await gate.open()
        for _ in 0..<32 {
            await Task.yield()
        }

        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .string), "**original**")
        controller.terminate()
        await tokenizer.shutdown()
    }

    @MainActor
    private func makePasteboard() -> PasteboardSnapshotFakePasteboard {
        PasteboardSnapshotFakePasteboard(items: [])
    }
}

private actor MarkdownCleanerExecutionState {
    private var mainThread: Bool?

    func record(isMainThread: Bool) {
        mainThread = isMainThread
    }

    func wasMainThread() -> Bool? {
        mainThread
    }
}

private actor MarkdownTextCapture {
    private var storedValue: String?

    func record(_ value: String) {
        storedValue = value
    }

    func value() -> String? {
        storedValue
    }
}

private actor MarkdownCleanerCallCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

private func isMainThreadSynchronously() -> Bool {
    Thread.isMainThread
}
