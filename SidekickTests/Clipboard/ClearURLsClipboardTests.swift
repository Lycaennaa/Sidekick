import AppKit
import XCTest
@MainActor
final class ClipboardClearURLsCleanerTests: XCTestCase {
    func testYouTubePlaylistParametersSurviveTrackingCleanup() throws {
        let cleaner = ClearURLsURLCleaner(ruleSet: try makeRuleSet())

        XCTAssertEqual(
            cleaner.clean(
                "https://www.youtube.com/watch?v=abc&list=PL123&index=2&si=tracking&utm_source=share"
            ),
            "https://www.youtube.com/watch?v=abc&list=PL123&index=2"
        )
    }

    func testCleanerPreservesWhitespaceAndUnknownParameters() throws {
        let cleaner = ClearURLsURLCleaner(ruleSet: try makeRuleSet())

        XCTAssertEqual(
            cleaner.clean("  https://example.com/article?keep=yes&utm_medium=email  "),
            "  https://example.com/article?keep=yes  "
        )
    }

    func testOversizedURLIsLeftUntouched() throws {
        let cleaner = ClearURLsURLCleaner(ruleSet: try makeRuleSet())
        let oversized = "https://example.com/?utm_source=" + String(repeating: "a", count: 128 * 1_024)

        XCTAssertEqual(cleaner.clean(oversized), oversized)
    }

    private func makeRuleSet() throws -> ClearURLsRuleSet {
        try ClearURLsRuleSet(data: Data(#"""
        {
            "providers": {
                "globalRules": {
                    "urlPattern": ".*",
                    "rules": ["(?:%3F)?utm(?:_[a-z_]*)?"],
                    "referralMarketing": [],
                    "rawRules": [],
                    "exceptions": [],
                    "redirections": [],
                    "completeProvider": false,
                    "forceRedirection": false
                },
                "youtube": {
                    "urlPattern": "^https?://.*(youtube\\.com|youtu\\.be)",
                    "rules": ["si", "feature", "gclid"],
                    "referralMarketing": [],
                    "rawRules": [],
                    "exceptions": [],
                    "redirections": [],
                    "completeProvider": false,
                    "forceRedirection": false
                }
            }
        }
        """#.utf8))
    }
}

@MainActor
final class ClipboardClearURLsControllerTests: XCTestCase {
    func testDefaultDependenciesCleanNamedPasteboard() async throws {
        let defaultsSuite = "ClipboardClearURLsControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipboardClearURLsControllerTests.\(UUID().uuidString)")
        )
        let settings = AppSettings(defaults: defaults)
        let cleaned = expectation(description: "Clipboard URL cleaned")
        var result: ClipboardClearURLsResult?
        let controller = try ClipboardClearURLsController(
            settings: settings,
            pasteboard: pasteboard,
            bundle: Bundle(for: ClipboardClearURLsControllerTests.self),
            onResult: { value in
                result = value
                if case .cleaned = value { cleaned.fulfill() }
            }
        )
        defer {
            controller.terminate()
            pasteboard.clearContents()
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        setText("baseline", on: pasteboard)
        controller.start()
        setText("https://example.com/article?keep=yes&utm_source=share", on: pasteboard)
        controller.poll()
        controller.poll()

        await fulfillment(of: [cleaned], timeout: 5)

        XCTAssertEqual(
            result,
            .cleaned(changeCount: pasteboard.changeCount)
        )
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "https://example.com/article?keep=yes"
        )
        XCTAssertEqual(
            pasteboard.string(forType: .URL),
            "https://example.com/article?keep=yes"
        )
    }

    func testNewerClipboardIsNotOverwrittenDuringAwaitedCapture() async throws {
        let defaultsSuite = "ClipboardClearURLsRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipboardClearURLsRace.\(UUID().uuidString)")
        )
        let reader = BlockingClearURLsPayloadReader()
        let rules = try ClearURLsRuleSet(
            data: Data(
                (#"{"providers":{"globalRules":{"urlPattern":".*","completeProvider":false,"rules":["utm"],"#
                    + #""referralMarketing":[],"rawRules":[],"exceptions":[],"#
                    + #""redirections":[],"forceRedirection":false}}}"#).utf8
            )
        )
        let settings = AppSettings(defaults: defaults)
        let newerClipboardCleaned = expectation(description: "Newer clipboard cleaned")
        let controller = try ClipboardClearURLsController(
            settings: settings,
            pasteboard: pasteboard,
            rules: rules,
            payloadReader: reader,
            onResult: { result in
                if case .cleaned = result { newerClipboardCleaned.fulfill() }
            }
        )
        defer {
            controller.terminate()
            pasteboard.clearContents()
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        setText("baseline", on: pasteboard)
        controller.start()
        setText("https://example.com/first?utm_source=one", on: pasteboard)
        controller.poll()
        controller.poll()
        await fulfillment(of: [reader.readStarted], timeout: 5)

        setText("https://example.com/newer?utm_source=two", on: pasteboard)
        controller.poll()
        reader.resumeBlockedRead()
        await fulfillment(of: [reader.readFinished], timeout: 5)

        controller.poll()
        await fulfillment(of: [newerClipboardCleaned], timeout: 5)

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "https://example.com/newer"
        )
        XCTAssertEqual(pasteboard.string(forType: .URL), "https://example.com/newer")
    }

    func testCancellingACompetingOperationRearmsCurrentClipboard() async throws {
        let defaultsSuite = "ClipboardClearURLsRearm.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipboardClearURLsRearm.\(UUID().uuidString)")
        )
        let cleaned = expectation(description: "Rearmed clipboard URL cleaned")
        let controller = try ClipboardClearURLsController(
            settings: AppSettings(defaults: defaults),
            pasteboard: pasteboard,
            rules: try makeClearURLsTestRuleSet(),
            onResult: { result in
                if case .cleaned = result { cleaned.fulfill() }
            }
        )
        defer {
            controller.terminate()
            pasteboard.clearContents()
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        setText("baseline", on: pasteboard)
        controller.start()
        setText("https://example.com/rearm?utm_source=one", on: pasteboard)
        controller.poll()
        let mutationGeneration = controller.beginClipboardMutation()
        controller.endClipboardMutation(mutationGeneration)
        controller.poll()

        await fulfillment(of: [cleaned], timeout: 5)

        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/rearm")
    }

    func testFailedReplacementDoesNotRetryRestoredClipboard() async throws {
        let defaultsSuite = "ClipboardClearURLsFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        let pasteboard = PasteboardSnapshotFakePasteboard(
            items: [makePasteboardSnapshotItem(text: "baseline")]
        )
        pasteboard.writeResults = [false, true, false, true]
        let failed = expectation(description: "Clipboard cleanup failure reported")
        let controller = try ClipboardClearURLsController(
            settings: AppSettings(defaults: defaults),
            pasteboard: pasteboard,
            rules: try makeClearURLsTestRuleSet(),
            onResult: { result in
                if case .replacementFailed = result { failed.fulfill() }
            }
        )
        defer {
            controller.terminate()
            defaults.removePersistentDomain(forName: defaultsSuite)
        }

        controller.start()
        pasteboard.items = [
            makePasteboardSnapshotItem(text: "https://example.com/failure?utm_source=one")
        ]
        pasteboard.changeCount += 1
        controller.poll()
        controller.poll()

        await fulfillment(of: [failed], timeout: 5)
        controller.poll()

        XCTAssertEqual(pasteboard.writeResults.count, 2)
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "https://example.com/failure?utm_source=one"
        )
    }

    private func setText(_ text: String, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(text, forType: .string))
        XCTAssertTrue(item.setString(text, forType: .URL))
        XCTAssertTrue(pasteboard.writeObjects([item]))
    }
}

@MainActor
private final class BlockingClearURLsPayloadReader: PasteboardPayloadReading {
    let readStarted = XCTestExpectation(description: "ClearURLs capture read started")
    let readFinished = XCTestExpectation(description: "ClearURLs capture read finished")

    private var blockNextRead = true
    private var continuation: CheckedContinuation<PasteboardPayloadReader.Result, Never>?
    private var blockedResult: PasteboardPayloadReader.Result?

    func readData(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int
    ) async -> PasteboardPayloadReader.Result {
        guard let data = item.data(forType: type), data.count <= maximumBytes else {
            return .missing
        }
        if blockNextRead {
            blockNextRead = false
            blockedResult = .data(data)
            readStarted.fulfill()
            let result = await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
            readFinished.fulfill()
            return result
        }
        return .data(data)
    }

    func resumeBlockedRead() {
        let continuation = continuation
        self.continuation = nil
        let result = blockedResult ?? .missing
        blockedResult = nil
        continuation?.resume(returning: result)
    }
}

private func makeClearURLsTestRuleSet() throws -> ClearURLsRuleSet {
    try ClearURLsRuleSet(data: Data(#"{"providers":{"globalRules":{"urlPattern":".*","rules":["utm"]}}}"#.utf8))
}
