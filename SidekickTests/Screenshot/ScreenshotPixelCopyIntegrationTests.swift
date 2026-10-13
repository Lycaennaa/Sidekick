import AppKit
import XCTest

@MainActor
final class ScreenshotPixelCopyIntegrationTests: XCTestCase {
    func testPixelValueSelectionWritesToRealNamedPasteboard() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ScreenshotPixelValue-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("prior clipboard value", forType: .string))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let metadataRegistry = ScreenshotClipboardMetadataRegistry()
        var pixelValueCopied = false
        var screenshotCopied = false
        var copySucceeded = false
        var failure: ScreenshotCaptureController.Failure?
        let copiedValues = [
            "Pixel: 0, 0",
            "HEX: #3366CC",
            "sRGB: 51, 102, 204",
            "Display P3: 0.200, 0.400, 0.800",
            "EDR RGB: unavailable (SDR)",
            "Selection: not selected"
        ].joined(separator: "\n")
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            capture: { _ in ScreenshotCaptureTestSupport.capturedScreenshot(from: image) },
            select: { _, copyPixelValues in
                copySucceeded = await copyPixelValues(copiedValues)
                return .cancelled
            },
            metadataRegistry: metadataRegistry,
            onCopied: { screenshotCopied = true },
            onPixelValueCopied: { pixelValueCopied = true },
            onFailure: { failure = $0 }
        )

        await controller.copyActiveDisplayToClipboard()

        XCTAssertTrue(pixelValueCopied)
        XCTAssertTrue(copySucceeded)
        XCTAssertFalse(screenshotCopied)
        XCTAssertNil(failure)
        XCTAssertEqual(pasteboard.string(forType: .string), copiedValues)
        XCTAssertNil(metadataRegistry.dynamicRange(forChangeCount: pasteboard.changeCount))
    }

    func testPixelValueCopyKeepsSelectionFlowOpenForScreenshotSelection() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ScreenshotCopyContinue-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("prior clipboard value", forType: .string))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        var pixelValueCopied = false
        var screenshotCopied = false
        var copySucceeded = false
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            capture: { _ in ScreenshotCaptureTestSupport.capturedScreenshot(from: image) },
            select: { screenshot, copyPixelValues in
                copySucceeded = await copyPixelValues("Pixel: 0, 0\nHEX: #000000")
                return .selected(screenshot.image)
            },
            onCopied: { screenshotCopied = true },
            onPixelValueCopied: { pixelValueCopied = true },
            onFailure: { failure = $0 }
        )

        await controller.copyActiveDisplayToClipboard()

        XCTAssertTrue(pixelValueCopied)
        XCTAssertTrue(copySucceeded)
        XCTAssertTrue(screenshotCopied)
        XCTAssertNil(failure)
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testPixelValueCopyReportsClipboardChangeBeforeAttemptingMutation() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(from: image)
        let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "initial")
        var copySucceeded = true
        var copied = false
        var failures: [ScreenshotCaptureController.Failure] = []
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            capture: { _ in screenshot },
            select: { _, copyPixelValues in
                pasteboard.replaceContents("newer clipboard value")
                copySucceeded = await copyPixelValues("Pixel: 0, 0\nHEX: #3366CC")
                return .cancelled
            },
            onCopied: { XCTFail("Pixel-value copy must not report an image copy") },
            onPixelValueCopied: { copied = true },
            onFailure: { failures.append($0) }
        )

        await controller.copyActiveDisplayToClipboard()

        XCTAssertFalse(copySucceeded)
        XCTAssertFalse(copied)
        XCTAssertEqual(failures, [.clipboardChanged])
        XCTAssertEqual(pasteboard.value, "newer clipboard value")
        XCTAssertEqual(pasteboard.writeCount, 0)
    }

    func testCancelledSelectionDoesNotReportClipboardChangeWithoutPixelCopy() async throws {
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(
            from: try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        )
        let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "initial")
        var failures: [ScreenshotCaptureController.Failure] = []
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            capture: { _ in screenshot },
            select: { _, _ in
                pasteboard.replaceContents("newer clipboard value")
                return .cancelled
            },
            onCopied: { XCTFail("Cancelled screenshot selection reported a copy") },
            onFailure: { failures.append($0) }
        )

        await controller.copyActiveDisplayToClipboard()

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(pasteboard.value, "newer clipboard value")
        XCTAssertEqual(pasteboard.writeCount, 0)
    }

    func testPixelValueSelectionKeepsClipboardChangesMadeDuringSelection() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(from: image)
        let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "initial")
        let gate = ScreenshotPixelValueSelectionGate()
        var copied = false
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            capture: { _ in screenshot },
            select: { _, _ in await gate.select() },
            onCopied: { XCTFail("Pixel-value selection must not report an image copy") },
            onPixelValueCopied: { copied = true },
            onFailure: { failure = $0 }
        )
        let operation = Task { @MainActor in
            await controller.copyActiveDisplayToClipboard()
        }

        await gate.waitUntilStarted()
        pasteboard.replaceContents("newer clipboard value")
        gate.resume(with: .copiedPixelValue("#3366CC"))
        await operation.value

        XCTAssertEqual(pasteboard.value, "newer clipboard value")
        XCTAssertEqual(pasteboard.writeCount, 0)
        XCTAssertFalse(copied)
        XCTAssertEqual(failure, .clipboardChanged)
    }

    func testPixelValueCopyPreservesNewerClipboardDuringSnapshot() async throws {
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(
            from: try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        )
        let originalItem = makePasteboardSnapshotItem(text: "initial")
        let newerItem = makePasteboardSnapshotItem(text: "newer clipboard value")
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [originalItem])
        pasteboard.beforeNextConditionalMutation = {
            pasteboard.items = [newerItem]
            pasteboard.changeCount += 1
        }
        var copied = false
        var copySucceeded = true
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            capture: { _ in screenshot },
            select: { _, copyPixelValues in
                copySucceeded = await copyPixelValues("Pixel: 0, 0\nHEX: #000000")
                return .cancelled
            },
            payloadReader: InlinePasteboardPayloadReader(),
            onCopied: { XCTFail("Pixel-value copy must not report an image copy") },
            onPixelValueCopied: { copied = true },
            onFailure: { failure = $0 }
        )

        await controller.copyActiveDisplayToClipboard()

        XCTAssertFalse(copied)
        XCTAssertEqual(failure, .clipboardChanged)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer clipboard value")
        XCTAssertFalse(copySucceeded)
    }

    @MainActor
    final class ScreenshotPixelValueSelectionGate {
        private var hasStarted = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var continuation: CheckedContinuation<ScreenshotSelectionResult, Never>?

        func select() async -> ScreenshotSelectionResult {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                hasStarted = true
                let waiters = startWaiters
                startWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }

        func waitUntilStarted() async {
            guard !hasStarted else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func resume(with result: ScreenshotSelectionResult) {
            continuation?.resume(returning: result)
            continuation = nil
        }
    }

}
