import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ScreenshotSaveTests: XCTestCase {

    func testDefaultSaveWritesDecodableWebPAndSuffixesCollisions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourcePNG = try pngData(width: 8, height: 4)

        let first = try ScreenshotSaveService.prepare(
            pngData: sourcePNG,
            directory: directory,
            baseName: "Window:Name",
            isCancelled: { false }
        )
        let firstURL = try ScreenshotSaveService.commit(first)
        let second = try ScreenshotSaveService.prepare(
            pngData: sourcePNG,
            directory: directory,
            baseName: "Window:Name",
            isCancelled: { false }
        )
        let secondURL = try ScreenshotSaveService.commit(second)

        XCTAssertEqual(firstURL.lastPathComponent, "Window-Name.webp")
        XCTAssertEqual(secondURL.lastPathComponent, "Window-Name (2).webp")
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(firstURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, UTType.webP.identifier)
        let decodedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(decodedImage.width, 8)
        XCTAssertEqual(decodedImage.height, 4)
    }

    func testPartialScreenshotWriteIsRemovedOnCancellation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent(".sidekick-screenshot-test.partial")
        let data = Data(repeating: 0xA5, count: 2 * 1_024 * 1_024)
        let cancellationChecks = ScreenshotWriteCancellationChecks()
        XCTAssertThrowsError(
            try ClipboardImageConversionFileService.writeOutput(data, to: output, isCancelled: {
                cancellationChecks.shouldCancel()
            })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellationChecks.count, 3)
        let remainingFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(remainingFiles.isEmpty)
    }

    func testSavePlusCopyWritesWebPAndSelectedPNGToRealPasteboard() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try makeSettings(directory: directory, template: "Screen")
        defer { configuration.defaults.removePersistentDomain(forName: configuration.suiteName) }
        let sourcePNG = try pngData(width: 8, height: 4)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(sourcePNG as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("prior clipboard", forType: .string))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        var savedURL: URL?
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: configuration.settings,
            capture: { _ in ScreenshotCaptureTestSupport.capturedScreenshot(from: image) },
            select: { _, _ in .saveAndCopy(image) },
            onCopied: { XCTFail("Save-plus-copy used copy-only completion") },
            onFailure: { failure = $0 },
            onSavedAndCopied: { savedURL = $0 }
        )

        await controller.copyActiveDisplayToClipboard(mode: .saveAndCopy)

        let outputURL = try XCTUnwrap(savedURL)
        XCTAssertEqual(outputURL.lastPathComponent, "Screen.webp")
        XCTAssertNil(failure)
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertNil(pasteboard.string(forType: .string))
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(outputURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, UTType.webP.identifier)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)
    }

    func testExplicitSaveActionOverridesCopyOnlyLaunchMode() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try makeSettings(directory: directory, template: "Screenshot")
        defer { configuration.defaults.removePersistentDomain(forName: configuration.suiteName) }
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(from: image)
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        var savedURL: URL?
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: configuration.settings,
            capture: { _ in screenshot },
            select: { _, _ in .saveAndCopy(image) },
            onCopied: { XCTFail("Explicit save action used copy-only completion") },
            onFailure: { failure = $0 },
            onSavedAndCopied: { savedURL = $0 }
        )

        await controller.copyActiveDisplayToClipboard(mode: .copy)

        XCTAssertEqual(try XCTUnwrap(savedURL).lastPathComponent, "Screenshot.webp")
        XCTAssertNil(failure)
        XCTAssertNotNil(pasteboard.data(forType: .png))
    }
    func testHUDCopyOnlyBypassesSaveForSaveAndCopyShortcut() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try makeSettings(directory: directory, template: "Screenshot")
        defer { configuration.defaults.removePersistentDomain(forName: configuration.suiteName) }
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(from: image)
        let pasteboard = makePasteboard()
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        var copied = false
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: configuration.settings,
            capture: { _ in screenshot },
            select: { _, _ in .copyOnly(image) },
            onCopied: { copied = true },
            onFailure: { failure = $0 },
            onSavedAndCopied: { _ in XCTFail("HUD copy-only action saved a file") }
        )

        await controller.copyActiveDisplayToClipboard(mode: .saveAndCopy)

        XCTAssertTrue(copied)
        XCTAssertNil(failure)
        XCTAssertNotNil(pasteboard.data(forType: .png))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty)
    }

    func testClipboardChangeAfterSaveKeepsFileAndReportsPartialSuccess() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try makeSettings(directory: directory, template: "Screenshot")
        defer { configuration.defaults.removePersistentDomain(forName: configuration.suiteName) }
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(from: image)
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [makePasteboardSnapshotItem(text: "before")])
        pasteboard.beforeNextConditionalMutation = {
            _ = pasteboard.setString("newer", forType: .string)
        }
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: configuration.settings,
            capture: { _ in screenshot },
            select: { _, _ in .selected(image) },
            payloadReader: InlinePasteboardPayloadReader(),
            onCopied: { XCTFail("Stale clipboard was reported as copied") },
            onFailure: { failure = $0 },
            onSavedAndCopied: { _ in XCTFail("Partial save was reported as copied") }
        )

        await controller.copyActiveDisplayToClipboard(mode: .saveAndCopy)

        XCTAssertEqual(failure, .savedButClipboardChanged)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer")
        let savedFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(savedFiles.map(\.pathExtension), ["webp"])
    }

    func testRestoreFailureAfterSaveReportsLostClipboardRecovery() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try makeSettings(directory: directory, template: "Screenshot")
        defer { configuration.defaults.removePersistentDomain(forName: configuration.suiteName) }
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(from: image)
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [makePasteboardSnapshotItem(text: "original")])
        pasteboard.writeResults = [false, false]
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: configuration.settings,
            capture: { _ in screenshot },
            select: { _, _ in .selected(image) },
            payloadReader: InlinePasteboardPayloadReader(),
            onCopied: { XCTFail("Clipboard restore failure was reported as copied") },
            onFailure: { failure = $0 },
            onSavedAndCopied: { _ in XCTFail("Clipboard restore failure was reported as copied") }
        )

        await controller.copyActiveDisplayToClipboard(mode: .saveAndCopy)

        XCTAssertEqual(failure, .savedButClipboardRestoreFailed)
        XCTAssertNil(pasteboard.string(forType: .string))
        let savedFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(savedFiles.map(\.pathExtension), ["webp"])
    }
    func testSaveFailureIsVisibleAndLeavesClipboardUnchanged() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidFolder = directory.appendingPathComponent("not-a-folder")
        try Data([1]).write(to: invalidFolder)
        let configuration = try makeSettings(directory: invalidFolder, template: "Screenshot")
        defer { configuration.defaults.removePersistentDomain(forName: configuration.suiteName) }
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(from: image)
        let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "keep me")
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: configuration.settings,
            capture: { _ in screenshot },
            select: { _, _ in .selected(image) },
            onCopied: { XCTFail("Failed save was reported as copied") },
            onFailure: { failure = $0 }
        )

        await controller.copyActiveDisplayToClipboard(mode: .saveAndCopy)

        XCTAssertEqual(failure, .save)
        XCTAssertEqual(pasteboard.value, "keep me")
        XCTAssertEqual(pasteboard.writeCount, 0)
    }

    func testOwnershipLossDuringSavePreparationDiscardsStagedFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try makeSettings(directory: directory, template: "Screenshot")
        defer { configuration.defaults.removePersistentDomain(forName: configuration.suiteName) }
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(from: image)
        let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "preserve")
        let gate = SavePreparationGate()
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: configuration.settings,
            capture: { _ in screenshot },
            select: { _, _ in .selected(image) },
            onCopied: { XCTFail("Terminated save was reported as copied") },
            onFailure: { XCTFail("Terminated save reported stale failure: \($0)") },
            prepareSave: { data, saveDirectory, baseName, format in
                let prepared = try ScreenshotSaveService.prepare(
                    pngData: data,
                    directory: saveDirectory,
                    baseName: baseName,
                    format: format,
                    isCancelled: { false }
                )
                return await gate.suspend(prepared)
            }
        )
        let operation = Task { @MainActor in
            await controller.copyActiveDisplayToClipboard(mode: .saveAndCopy)
        }

        await gate.waitUntilStarted()
        XCTAssertTrue(controller.hasPendingSavePreparation)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
        controller.terminate()
        operation.cancel()
        gate.resume()
        await operation.value

        XCTAssertFalse(controller.hasPendingSavePreparation)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertEqual(pasteboard.value, "preserve")
        XCTAssertEqual(pasteboard.writeCount, 0)
    }

    func testClipboardChangeDuringSavePreparationDiscardsStageAndPreservesNewContents() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try makeSettings(directory: directory, template: "Screenshot")
        defer { configuration.defaults.removePersistentDomain(forName: configuration.suiteName) }
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(from: image)
        let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "before")
        let gate = SavePreparationGate()
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: configuration.settings,
            capture: { _ in screenshot },
            select: { _, _ in .selected(image) },
            onCopied: { XCTFail("Stale clipboard was replaced") },
            onFailure: { failure = $0 },
            prepareSave: { data, saveDirectory, baseName, format in
                let prepared = try ScreenshotSaveService.prepare(
                    pngData: data,
                    directory: saveDirectory,
                    baseName: baseName,
                    format: format,
                    isCancelled: { false }
                )
                return await gate.suspend(prepared)
            }
        )
        let operation = Task { @MainActor in
            await controller.copyActiveDisplayToClipboard(mode: .saveAndCopy)
        }

        await gate.waitUntilStarted()
        pasteboard.replaceContents("newer")
        gate.resume()
        await operation.value

        XCTAssertEqual(failure, .clipboardChanged)
        XCTAssertEqual(pasteboard.value, "newer")
        XCTAssertEqual(pasteboard.writeCount, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCancellationCheckCounterSerializesConcurrentCalls() async {
        let checks = ScreenshotWriteCancellationChecks()
        var cancellations = 0
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<64 {
                group.addTask { checks.shouldCancel() }
            }
            for await shouldCancel in group where shouldCancel {
                cancellations += 1
            }
        }
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(checks.count, 64)
    }

    @MainActor
    private final class SavePreparationGate {
        private var hasStarted = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var preparedContinuation: CheckedContinuation<Void, Never>?

        func suspend(_ prepared: ScreenshotSaveService.Prepared) async -> ScreenshotSaveService.Prepared {
            hasStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { preparedContinuation = $0 }
            return prepared
        }

        func waitUntilStarted() async {
            guard !hasStarted else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func resume() {
            preparedContinuation?.resume()
            preparedContinuation = nil
        }
    }
}

@MainActor
private struct ScreenshotSaveSettingsConfiguration {
    let settings: AppSettings
    let defaults: UserDefaults
    let suiteName: String
}

@MainActor
private func makeSettings(directory: URL, template: String) throws -> ScreenshotSaveSettingsConfiguration {
    let suiteName = "ScreenshotSaveTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let settings = AppSettings(defaults: defaults)
    settings.screenshotSaveDirectoryURL = directory
    settings.screenshotFilenameTemplate = template
    return ScreenshotSaveSettingsConfiguration(settings: settings, defaults: defaults, suiteName: suiteName)
}

private final class ScreenshotWriteCancellationChecks: @unchecked Sendable {
    // The lock protects the counter shared by the cancellation closure and test through synchronous write completion.
    private let lock = NSLock()
    private var checkCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return checkCount
    }

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checkCount += 1
        return checkCount == 3
    }
}
