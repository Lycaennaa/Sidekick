import AppKit
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ScreenshotWebPCopyIntegrationTests: XCTestCase {
    func testScreenshotWritesWebPToRealPasteboard() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let suiteName = "ScreenshotWebPCopy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.screenshotCopyAsWebP = true
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ScreenshotWebP-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("prior clipboard value", forType: .string))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        var copied = false
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: settings,
            capture: { _ in ScreenshotCaptureTestSupport.capturedScreenshot(from: image) },
            select: { _, _, _, _ in .selected(image) },
            onCopied: { copied = true },
            onFailure: { failure = $0 }
        )

        await controller.copyActiveDisplayToClipboard()

        XCTAssertTrue(copied)
        XCTAssertNil(failure)
        let webPType = NSPasteboard.PasteboardType(UTType.webP.identifier)
        let webPData = try XCTUnwrap(pasteboard.data(forType: webPType))
        XCTAssertNil(pasteboard.data(forType: .png))
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(webPData as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(imageSource) as String?, UTType.webP.identifier)
        let decodedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(decodedImage.width, image.width)
        XCTAssertEqual(decodedImage.height, image.height)
    }

    func testSaveAndCopyReusesStagedWebPEncoding() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "ScreenshotWebPSaveCopy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.screenshotCopyAsWebP = true
        settings.screenshotSaveDirectoryURL = directory
        settings.screenshotFilenameTemplate = "Screenshot"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ScreenshotWebPSaveCopy-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("prior clipboard value", forType: .string))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        var savedURL: URL?
        var failure: ScreenshotCaptureController.Failure?
        var clipboardWebPPreparations = 0
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: settings,
            capture: { _ in ScreenshotCaptureTestSupport.capturedScreenshot(from: image) },
            select: { _, _, _, _ in .selected(image) },
            onCopied: { XCTFail("Save-and-copy used copy-only completion") },
            onFailure: { failure = $0 },
            onSavedAndCopied: { savedURL = $0 },
            prepareClipboardWebP: { pngData in
                clipboardWebPPreparations += 1
                return try await ClipboardWebPEncoder.encodeInBackground(pngData)
            }
        )

        await controller.copyActiveDisplayToClipboard(mode: .saveAndCopy)

        let outputURL = try XCTUnwrap(savedURL)
        XCTAssertNil(failure)
        XCTAssertEqual(clipboardWebPPreparations, 0)
        let webPData = try XCTUnwrap(
            pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.webP.identifier))
        )
        XCTAssertNil(pasteboard.data(forType: .png))
        XCTAssertEqual(try Data(contentsOf: outputURL), webPData)
    }

    func testWebPCopyPreservesClipboardChangedDuringEncoding() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let suiteName = "ScreenshotWebPRace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.screenshotCopyAsWebP = true
        let pasteboard = PasteboardSnapshotFakePasteboard(
            items: [makePasteboardSnapshotItem(text: "before")]
        )
        let gate = ScreenshotWebPPreparationGate()
        var copied = false
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: settings,
            capture: { _ in ScreenshotCaptureTestSupport.capturedScreenshot(from: image) },
            select: { _, _, _, _ in .selected(image) },
            payloadReader: InlinePasteboardPayloadReader(),
            onCopied: { copied = true },
            onFailure: { failure = $0 },
            prepareClipboardWebP: { pngData in
                let webPData = try await ClipboardWebPEncoder.encodeInBackground(pngData)
                return await gate.suspend(webPData)
            }
        )
        let operation = Task { @MainActor in
            await controller.copyActiveDisplayToClipboard()
        }

        await gate.waitUntilStarted()
        XCTAssertTrue(pasteboard.setString("newer", forType: .string))
        gate.resume()
        await operation.value

        XCTAssertFalse(copied)
        XCTAssertEqual(failure, .clipboardChanged)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer")
    }

    func testWebPCopyFailurePreservesExistingClipboard() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let suiteName = "ScreenshotWebPFailure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.screenshotCopyAsWebP = true
        let pasteboard = PasteboardSnapshotFakePasteboard(
            items: [makePasteboardSnapshotItem(text: "preserve")]
        )
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: settings,
            capture: { _ in ScreenshotCaptureTestSupport.capturedScreenshot(from: image) },
            select: { _, _, _, _ in .selected(image) },
            onCopied: { XCTFail("Failed WebP encoding was reported as copied") },
            onFailure: { failure = $0 },
            prepareClipboardWebP: { _ in throw ClipboardWebPConversionError.cannotEncode }
        )

        await controller.copyActiveDisplayToClipboard()

        XCTAssertEqual(failure, .encoding)
        XCTAssertEqual(pasteboard.string(forType: .string), "preserve")
        XCTAssertEqual(pasteboard.changeCount, 1)
    }

    @MainActor
    private final class ScreenshotWebPPreparationGate {
        private var hasStarted = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var continuation: CheckedContinuation<Void, Never>?

        func suspend(_ data: Data) async -> Data {
            hasStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation = $0 }
            return data
        }

        func waitUntilStarted() async {
            guard !hasStarted else { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }
}
