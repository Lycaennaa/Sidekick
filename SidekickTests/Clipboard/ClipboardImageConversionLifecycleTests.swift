import AppKit
import XCTest

final class ClipboardImageConversionLifecycleTests: XCTestCase {
    @MainActor
    func testExpirationClearsOnlyUnchangedConvertedClipboard() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let controller = ClipboardImageConversionController(
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
        let controller = ClipboardImageConversionController(
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
        let controller = ClipboardImageConversionController(
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
        let controller = ClipboardImageConversionController(
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
        let referencesArtifact = await ClipboardImageConversionPasteboardCapture.referencesFile(
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
        let legacyDirectory = directory.appendingPathComponent("Sidekick-ClipboardWebP", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let referencedURL = legacyDirectory.appendingPathComponent("Ref1234.webp")
        let staleURL = legacyDirectory.appendingPathComponent("Stale01.webp")
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

        let owner = ClipboardImageConversionArtifactOwner(
            expirationInterval: 60,
            outputDirectory: directory,
            legacyOutputDirectories: [legacyDirectory],
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

        let relaunchStaleURL = legacyDirectory.appendingPathComponent("Relnch1.webp")
        try Data([3]).write(to: relaunchStaleURL)
        let relaunchedOwner = ClipboardImageConversionArtifactOwner(
            expirationInterval: 60,
            outputDirectory: directory,
            legacyOutputDirectories: [legacyDirectory],
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
        let controller = ClipboardImageConversionController(
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
        let controller = ClipboardImageConversionController(
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
        let controller = ClipboardImageConversionController(
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
        var result: ClipboardImageConversionController.Result?
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
        let worker = ClipboardImageConversionWorker(convert: { _, outputDirectory, _, _ in
            workerStarted.mark()
            return outputDirectory.appendingPathComponent("unexpected.webp")
        })
        var messages: [String] = []
        let controller = ClipboardImageConversionController(
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
    func testCancellingSnapshotCapturePreventsConversionSideEffects() async throws {
        let sourceURL = URL(fileURLWithPath: "/missing/source.png")
        let sourceItem = NSPasteboardItem()
        XCTAssertTrue(sourceItem.setString(sourceURL.absoluteString, forType: .fileURL))
        XCTAssertTrue(sourceItem.setString("clipboard metadata", forType: .string))
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [sourceItem])
        let reader = InstallBlockingPayloadReader()
        let directory = try temporaryDirectory()
        let outputURL = directory.appendingPathComponent("Inst001.webp")
        let workerStarted = ThreadSafeFlag()
        var converted = false
        var result: ClipboardImageConversionController.Result?
        let completion = expectation(description: "Cancelled snapshot capture completion")
        let worker = ClipboardImageConversionWorker(convert: { _, _, _, _ in
            workerStarted.mark()
            return outputURL
        })
        let controller = ClipboardImageConversionController(
            pasteboard: pasteboard,
            outputDirectory: directory,
            worker: worker,
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: reader,
            onConverted: { _, _ in converted = true },
            onMessage: { _ in }
        )
        defer {
            controller.terminate()
            reader.resume(.cancelled)
            try? FileManager.default.removeItem(at: directory)
        }

        controller.convertClipboardImage {
            result = $0
            completion.fulfill()
        }
        await fulfillment(of: [reader.captureReadStarted], timeout: 5)

        controller.cancelPendingConversion()
        reader.resume(.data(Data("clipboard metadata".utf8)))
        await fulfillment(of: [completion], timeout: 5)

        XCTAssertEqual(result, .stale)
        XCTAssertFalse(workerStarted.value)
        XCTAssertFalse(converted)
        XCTAssertEqual(pasteboard.items.first?.string(forType: .fileURL), sourceURL.absoluteString)
        XCTAssertEqual(pasteboard.items.first?.string(forType: .string), "clipboard metadata")
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
private final class InstallBlockingPayloadReader: PasteboardPayloadReading {
    let captureReadStarted = XCTestExpectation(description: "Rollback snapshot payload read started")
    private var continuation: CheckedContinuation<PasteboardPayloadReader.Result, Never>?

    func readData(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int
    ) async -> PasteboardPayloadReader.Result {
        if type == .string {
            captureReadStarted.fulfill()
            return await withCheckedContinuation { continuation = $0 }
        }
        guard let data = item.data(forType: type) else { return .missing }
        guard data.count <= maximumBytes else {
            return .tooLarge(byteCount: data.count)
        }
        return .data(data)
    }

    func resume(_ result: PasteboardPayloadReader.Result) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }
}
