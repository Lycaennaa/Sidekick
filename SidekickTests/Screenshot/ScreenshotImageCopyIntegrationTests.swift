import AppKit
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ScreenshotImageCopyIntegrationTests: XCTestCase {
    func testScreenshotWritesWebPToRealPasteboard() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let suiteName = "ScreenshotImageCopy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.screenshotCopyAsOutputFormat = true
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ScreenshotImageCopyPasteboard-\(UUID().uuidString)"))
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
            select: { _, _ in .selected(image) },
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

    @MainActor
    func testAutomaticConversionKeepsScreenshotOutputFileBacked() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let suiteName = "ScreenshotAutoImageCopy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.automaticImageConversionEnabled = true
        settings.screenshotCopyAsOutputFormat = false
        settings.imageOutputFormat = .webP

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ScreenshotAutoImageCopy-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("prior clipboard value", forType: .string))
        let outputDirectory = try temporaryDirectory()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let converted = expectation(description: "Screenshot clipboard converted")
        var outputURL: URL?
        let controllers = makeAutomaticScreenshotConversionControllers(
            settings: settings,
            pasteboard: pasteboard,
            outputDirectory: outputDirectory,
            onConverted: { url in
                outputURL = url
                converted.fulfill()
            }
        )
        controllers.automatic.start()
        defer {
            controllers.automatic.terminate()
            controllers.conversion.terminate()
        }

        var copied = false
        var failure: ScreenshotCaptureController.Failure?
        let screenshotController = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: settings,
            capture: { _ in ScreenshotCaptureTestSupport.capturedScreenshot(from: image) },
            select: { _, _ in .selected(image) },
            onCopied: { copied = true },
            onFailure: { failure = $0 }
        )
        await screenshotController.copyActiveDisplayToClipboard()
        await controllers.automatic.poll()
        await fulfillment(of: [converted], timeout: 10)

        XCTAssertTrue(copied)
        XCTAssertNil(failure)
        let convertedURL = try XCTUnwrap(outputURL)
        try assertFileBackedWebP(on: pasteboard, outputURL: convertedURL)
        controllers.automatic.terminate()
        controllers.conversion.terminate()
        await controllers.conversion.waitForTerminationCleanup()
    }

    private func makeAutomaticScreenshotConversionControllers(
        settings: AppSettings,
        pasteboard: NSPasteboard,
        outputDirectory: URL,
        onConverted: @escaping (URL) -> Void
    ) -> (
        automatic: ClipboardAutoImageConversionController,
        conversion: ClipboardImageConversionController
    ) {
        let conversion = ClipboardImageConversionController(
            pasteboard: pasteboard,
            outputDirectory: outputDirectory,
            outputFormat: { settings.imageOutputFormat },
            onConverted: { url, _ in onConverted(url) },
            onMessage: { message in XCTFail("Unexpected conversion message: \(message)") }
        )
        let automatic = ClipboardAutoImageConversionController(
            settings: settings,
            pasteboard: pasteboard,
            onCaptureResult: { capture, format in
                guard case let .source(source) = capture else {
                    XCTFail("Expected screenshot PNG capture, got \(capture)")
                    conversion.reportCaptureFailure(capture)
                    return
                }
                conversion.convertCapturedClipboardImage(source, outputFormat: format)
            }
        )
        return (automatic, conversion)
    }

    private func assertFileBackedWebP(on pasteboard: NSPasteboard, outputURL: URL) throws {
        XCTAssertNil(pasteboard.data(forType: .png))
        let webPData = try XCTUnwrap(
            pasteboard.data(forType: NSPasteboard.PasteboardType(ClipboardImageFormat.webP.typeIdentifier))
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithData(webPData as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, ClipboardImageFormat.webP.typeIdentifier)
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(try Data(contentsOf: outputURL), webPData)
        XCTAssertEqual(outputURL.pathExtension, ClipboardImageFormat.webP.fileExtension)
        XCTAssertEqual(pasteboard.string(forType: .fileURL), outputURL.absoluteString)
    }

    func testSaveAndCopyReusesStagedSelectedFormatEncoding() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "ScreenshotImageCopySaveCopy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.screenshotCopyAsOutputFormat = true
        settings.imageOutputFormat = .webP
        settings.screenshotSaveDirectoryURL = directory
        settings.screenshotFilenameTemplate = "Screenshot"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ScreenshotImageCopySaveCopy-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("prior clipboard value", forType: .string))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        var savedURL: URL?
        var failure: ScreenshotCaptureController.Failure?
        var clipboardImagePreparations = 0
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: settings,
            capture: { _ in ScreenshotCaptureTestSupport.capturedScreenshot(from: image) },
            select: { _, _ in .selected(image) },
            onCopied: { XCTFail("Save-and-copy used copy-only completion") },
            onFailure: { failure = $0 },
            onSavedAndCopied: { savedURL = $0 },
            prepareClipboardImage: { pngData, format in
                clipboardImagePreparations += 1
                return try await ClipboardImageEncoder.encodeInBackground(pngData, format: format)
            }
        )

        await controller.copyActiveDisplayToClipboard(mode: .saveAndCopy)

        let outputURL = try XCTUnwrap(savedURL)
        XCTAssertNil(failure)
        XCTAssertEqual(clipboardImagePreparations, 0)
        XCTAssertEqual(outputURL.pathExtension, ClipboardImageFormat.webP.fileExtension)
        let webPData = try XCTUnwrap(
            pasteboard.data(forType: NSPasteboard.PasteboardType(ClipboardImageFormat.webP.typeIdentifier))
        )
        XCTAssertNil(pasteboard.data(forType: .png))
        XCTAssertEqual(try Data(contentsOf: outputURL), webPData)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(webPData as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, ClipboardImageFormat.webP.typeIdentifier)
    }

    func testImageCopyPreservesClipboardChangedDuringEncoding() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let suiteName = "ScreenshotImageCopyRace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.screenshotCopyAsOutputFormat = true
        let pasteboard = PasteboardSnapshotFakePasteboard(
            items: [makePasteboardSnapshotItem(text: "before")]
        )
        let gate = ScreenshotImagePreparationGate()
        var copied = false
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: settings,
            capture: { _ in ScreenshotCaptureTestSupport.capturedScreenshot(from: image) },
            select: { _, _ in .selected(image) },
            payloadReader: InlinePasteboardPayloadReader(),
            onCopied: { copied = true },
            onFailure: { failure = $0 },
            prepareClipboardImage: { pngData, format in
                let outputData = try await ClipboardImageEncoder.encodeInBackground(pngData, format: format)
                return await gate.suspend(outputData)
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

    func testImageCopyFailurePreservesExistingClipboard() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let suiteName = "ScreenshotImageCopyFailure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.screenshotCopyAsOutputFormat = true
        let pasteboard = PasteboardSnapshotFakePasteboard(
            items: [makePasteboardSnapshotItem(text: "preserve")]
        )
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: settings,
            capture: { _ in ScreenshotCaptureTestSupport.capturedScreenshot(from: image) },
            select: { _, _ in .selected(image) },
            onCopied: { XCTFail("Failed image encoding was reported as copied") },
            onFailure: { failure = $0 },
            prepareClipboardImage: { _, _ in throw ClipboardImageConversionError.cannotEncode }
        )

        await controller.copyActiveDisplayToClipboard()

        XCTAssertEqual(failure, .encoding)
        XCTAssertEqual(pasteboard.string(forType: .string), "preserve")
        XCTAssertEqual(pasteboard.changeCount, 1)
    }

    @MainActor
    private final class ScreenshotImagePreparationGate {
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
