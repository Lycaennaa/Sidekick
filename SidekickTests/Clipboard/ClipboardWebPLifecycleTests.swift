import AppKit
import XCTest

final class ClipboardWebPLifecycleTests: XCTestCase {
    @MainActor
    func testExpirationClearsOnlyUnchangedConvertedClipboard() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            expirationInterval: 0.05,
            outputDirectory: directory,
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader(),
            onMessage: { _ in }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        pasteboard.clearContents()
        pasteboard.setData(try pngData(width: 2, height: 2), forType: .png)
        let result = await convert(with: controller)
        guard case let .converted(url) = result else {
            return XCTFail("Expected converted WebP")
        }

        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testExpirationPreservesNewClipboardContent() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            expirationInterval: 0.05,
            outputDirectory: directory,
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader(),
            onMessage: { _ in }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        pasteboard.clearContents()
        pasteboard.setData(try pngData(width: 2, height: 2), forType: .png)
        let result = await convert(with: controller)
        guard case let .converted(url) = result else {
            return XCTFail("Expected converted WebP")
        }

        pasteboard.clearContents()
        pasteboard.setString("new clipboard value", forType: .string)
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(pasteboard.string(forType: .string), "new clipboard value")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    @MainActor
    func testTerminationClearsAndDeletesUnchangedConvertedClipboard() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            outputDirectory: directory,
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader(),
            onMessage: { _ in }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        pasteboard.clearContents()
        pasteboard.setData(try pngData(width: 2, height: 2), forType: .png)
        guard case let .converted(url) = await convert(with: controller) else {
            return XCTFail("Expected converted WebP")
        }

        controller.terminate()
        await controller.waitForTerminationCleanup()

        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testTerminationPreservesMultiItemClipboardReferencingArtifact() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            expirationInterval: 60,
            outputDirectory: directory,
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader(),
            onMessage: { _ in }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        pasteboard.clearContents()
        pasteboard.setData(try pngData(width: 2, height: 2), forType: .png)
        let result = await convert(with: controller)
        guard case let .converted(url) = result else {
            return XCTFail("Expected converted WebP")
        }

        let ownedItem = NSPasteboardItem()
        XCTAssertTrue(ownedItem.setString(url.absoluteString, forType: .fileURL))
        let unrelatedItem = NSPasteboardItem()
        XCTAssertTrue(unrelatedItem.setString("unrelated", forType: .string))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([ownedItem, unrelatedItem]))

        controller.terminate()

        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "unrelated")
        let referencesArtifact = await ClipboardWebPPasteboardCapture.referencesFile(
            url,
            pasteboard: pasteboard,
            fileURLReader: InlinePasteboardFileURLReader()
        )
        XCTAssertTrue(referencesArtifact)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testRelaunchStartupCleanupPreservesReferencedArtifact() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let referencedURL = directory.appendingPathComponent("Ref1234.webp")
        let staleURL = directory.appendingPathComponent("Stale01.webp")
        try Data([1]).write(to: referencedURL)
        try Data([2]).write(to: staleURL)
        let unrelatedURL = directory.appendingPathComponent("unrelated.webp")
        let ownedDirectory = directory.appendingPathComponent("Dir1234.webp")
        try Data([4]).write(to: unrelatedURL)
        try FileManager.default.createDirectory(at: ownedDirectory, withIntermediateDirectories: false)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(referencedURL.absoluteString, forType: .fileURL))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let owner = ClipboardWebPArtifactOwner(
            expirationInterval: 60,
            outputDirectory: directory,
            pasteboard: pasteboard,
            fileURLReader: InlinePasteboardFileURLReader(),
            currentGeneration: { pasteboard.changeCount }
        )
        defer {
            owner.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        await owner.waitForStartupCleanup()

        XCTAssertTrue(FileManager.default.fileExists(atPath: referencedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedDirectory.path))

        let relaunchStaleURL = directory.appendingPathComponent("Relnch1.webp")
        try Data([3]).write(to: relaunchStaleURL)
        let relaunchedOwner = ClipboardWebPArtifactOwner(
            expirationInterval: 60,
            outputDirectory: directory,
            pasteboard: pasteboard,
            fileURLReader: InlinePasteboardFileURLReader(),
            currentGeneration: { pasteboard.changeCount }
        )
        defer { relaunchedOwner.terminate() }
        await relaunchedOwner.waitForStartupCleanup()

        XCTAssertTrue(FileManager.default.fileExists(atPath: referencedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: relaunchStaleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedDirectory.path))
    }
    @MainActor
    func testGenerationChangeBeforeInstallationPreservesNewClipboard() async throws {
        let sourceItem = NSPasteboardItem()
        sourceItem.setData(try pngData(width: 2, height: 2), forType: .png)
        let replacementItem = NSPasteboardItem()
        replacementItem.setString("new clipboard value", forType: .string)
        let pasteboard = GenerationChangingPasteboard(
            items: [sourceItem],
            replacementItems: [replacementItem]
        )
        let directory = try temporaryDirectory()
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            outputDirectory: directory,
             payloadReader: InlinePasteboardPayloadReader(),
            onMessage: { _ in }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        let result = await convert(with: controller)

        XCTAssertEqual(result, .stale)
        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.string(forType: .string),
            "new clipboard value"
        )
        XCTAssertNil(pasteboard.pasteboardItems?.first?.data(forType: .png))
    }

    @MainActor
    func testConditionalReplacementRacePreservesNewClipboard() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            outputDirectory: directory,
             payloadReader: InlinePasteboardPayloadReader(),
            onMessage: { _ in }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        pasteboard.clearContents()
        pasteboard.setData(try pngData(width: 2, height: 2), forType: .png)
        pasteboard.beforeNextConditionalMutation = {
            pasteboard.setString("new clipboard value", forType: .string)
        }

        let result = await convert(with: controller)

        XCTAssertEqual(result, .stale)
        XCTAssertEqual(pasteboard.string(forType: .string), "new clipboard value")
    }

    @MainActor
    func testCancellingPendingConversionPreservesClipboardImage() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            outputDirectory: directory,
             payloadReader: InlinePasteboardPayloadReader(),
            onMessage: { _ in }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        pasteboard.clearContents()
        pasteboard.setData(try pngData(width: 2_000, height: 2_000), forType: .png)
        let completion = expectation(description: "Cancelled conversion completion")
        var result: ClipboardWebPController.Result?
        controller.convertClipboardImage {
            result = $0
            completion.fulfill()
        }

        controller.cancelPendingConversion()
        await fulfillment(of: [completion], timeout: 5)

        XCTAssertEqual(result, .stale)
        XCTAssertNotNil(pasteboard.data(forType: .png))
    }

    @MainActor
    func testFileURLTimeoutDoesNotStartConversionOrInstall() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let target = URL(fileURLWithPath: "/tmp/timeout.webp")
        let reader = TimeoutFileURLReader()
        let workerStarted = ThreadSafeFlag()
        let worker = ClipboardWebPWorker(convert: { _, outputDirectory, _ in
            workerStarted.mark()
            return outputDirectory.appendingPathComponent("unexpected.webp")
        })
        var messages: [String] = []
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            outputDirectory: directory,
            worker: worker,
            fileURLReader: reader,
            onMessage: { messages.append($0) }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(target.absoluteString, forType: .fileURL))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let result = await convert(with: controller)

        XCTAssertEqual(result, .stale)
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertFalse(workerStarted.value)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertEqual(pasteboard.string(forType: .fileURL), target.absoluteString)
    }

    @MainActor
    func testCancellingOwnedInstallPreventsSuccessSideEffects() async throws {
        let sourceURL = URL(fileURLWithPath: "/missing/source.png")
        let sourceItem = NSPasteboardItem()
        XCTAssertTrue(sourceItem.setString(sourceURL.absoluteString, forType: .fileURL))
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [sourceItem])
        let reader = InstallBlockingFileURLReader(sourceURL: sourceURL)
        let directory = try temporaryDirectory()
        let outputURL = directory.appendingPathComponent(
            "Inst001.webp"
        )
        var converted = false
        var result: ClipboardWebPController.Result?
        let completion = expectation(description: "Cancelled install completion")
        let worker = ClipboardWebPWorker(convert: { _, _, _ in outputURL })
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            outputDirectory: directory,
            worker: worker,
            fileURLReader: reader,
            onConverted: { _, _ in converted = true },
            onMessage: { _ in }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        controller.convertClipboardImage {
            result = $0
            completion.fulfill()
        }
        await fulfillment(of: [reader.installReadStarted], timeout: 5)

        controller.cancelPendingConversion()
        reader.resume(.data(reader.sourceData))
        await fulfillment(of: [completion], timeout: 5)

        XCTAssertEqual(result, .stale)
        XCTAssertFalse(converted)
        XCTAssertEqual(pasteboard.items.first?.string(forType: .fileURL), sourceURL.absoluteString)
    }
}
@MainActor
private final class TimeoutFileURLReader: PasteboardFileURLReading {
    private(set) var readCount = 0

    func readFileURLData(
        from item: NSPasteboardItem,
        maximumBytes: Int,
        timeout: TimeInterval
    ) async -> PasteboardFileURLReadResult {
        readCount += 1
        return .timedOut
    }
}

private final class ThreadSafeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var markedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return markedValue
    }

    func mark() {
        lock.lock()
        markedValue = true
        lock.unlock()
    }
}

@MainActor
private final class InstallBlockingFileURLReader: PasteboardFileURLReading {
    let sourceData: Data
    let installReadStarted = XCTestExpectation(description: "Install file URL read started")
    private var continuation: CheckedContinuation<PasteboardFileURLReadResult, Never>?
    private var readCount = 0

    init(sourceURL: URL) {
        sourceData = Data(sourceURL.absoluteString.utf8)
    }

    func readFileURLData(
        from item: NSPasteboardItem,
        maximumBytes: Int,
        timeout: TimeInterval
    ) async -> PasteboardFileURLReadResult {
        readCount += 1
        guard readCount == 2 else { return .data(sourceData) }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            installReadStarted.fulfill()
        }
    }

    func resume(_ result: PasteboardFileURLReadResult) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }
}
