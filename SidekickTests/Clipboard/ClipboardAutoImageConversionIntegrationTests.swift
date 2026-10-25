import AppKit
import ImageIO
import XCTest

final class ClipboardAutoImageConversionIntegrationTests: XCTestCase {
    @MainActor
    func testAutomaticConversionIgnoresCopiedFolder() async throws {
        let suiteName = "ClipboardAutoFolder.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.automaticImageConversionEnabled = true

        let sourceDirectory = try temporaryDirectory()
        let folderURL = sourceDirectory.appendingPathComponent("folder.png")
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let pasteboard = makePasteboard()
        var conversionRequestCount = 0
        let controller = ClipboardAutoImageConversionController(
            settings: settings,
            pasteboard: pasteboard,
            onCaptureResult: { _, _ in conversionRequestCount += 1 }
        )
        controller.start()
        defer {
            controller.terminate()
            pasteboard.clearContents()
            try? FileManager.default.removeItem(at: sourceDirectory)
        }

        pasteboard.clearContents()
        XCTAssertTrue(AutomaticClipboardInput.fileURL(folderURL).write(to: pasteboard))
        await controller.poll()
        await controller.poll()

        XCTAssertEqual(conversionRequestCount, 0)
    }

    @MainActor
    func testAutomaticConvertsRealPasteboardPNGToWebP() async throws {
        try await assertAutomaticReencode(
            input: .data(try pngData(width: 4, height: 3), type: .png),
            outputFormat: .webP
        )
    }

    @MainActor
    func testAutomaticReencodesWebPBytesAdvertisedAsPNG() async throws {
        let sourcePNG = try pngData(width: 4, height: 3)
        let sourceWebP = try ClipboardImageEncoder.encode(
            sourcePNG,
            format: .webP,
            isCancelled: { false }
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithData(sourceWebP as CFData, nil))
        XCTAssertEqual(
            CGImageSourceGetType(source) as String?,
            ClipboardImageFormat.webP.typeIdentifier
        )

        try await assertAutomaticReencode(
            input: .data(sourceWebP, type: .png),
            outputFormat: .webP
        )
    }

    @MainActor
    func testAutomaticConvertsRealPasteboardPNGToAVIF() async throws {
        try await assertAutomaticReencode(
            input: .data(try pngData(width: 4, height: 3), type: .png),
            outputFormat: .avif
        )
    }

    @MainActor
    func testAutomaticConvertsExtensionlessClipboardImageToWebP() async throws {
        let sourceDirectory = try temporaryDirectory()
        let sourceURL = sourceDirectory.appendingPathComponent("image")
        try pngData(width: 3, height: 2).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }

        try await assertAutomaticReencode(
            input: .fileURL(sourceURL),
            outputFormat: .webP
        )
    }

    @MainActor
    private func assertAutomaticReencode(
        input: AutomaticClipboardInput,
        outputFormat: ClipboardImageFormat
    ) async throws {
        let suiteName = "ClipboardAutoImageConversionIntegration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.automaticImageConversionEnabled = true
        settings.imageOutputFormat = outputFormat

        let pasteboard = makePasteboard()
        let outputDirectory = try temporaryDirectory()
        let converted = expectation(description: "Clipboard image converted")
        var convertedURL: URL?
        var conversionRequestCount = 0
        var acknowledgeConvertedChange: ((Int) -> Void)?
        let converter = ClipboardImageConversionController(
            pasteboard: pasteboard,
            outputDirectory: outputDirectory,
            outputFormat: { settings.imageOutputFormat },
            onConverted: { url, changeCount in
                acknowledgeConvertedChange?(changeCount)
                convertedURL = url
                converted.fulfill()
            },
            onMessage: { _ in }
        )
        let controller = ClipboardAutoImageConversionController(
            settings: settings,
            pasteboard: pasteboard,
            onCaptureResult: {
                enqueueAutomaticCapture($0, format: $1, converter: converter, requestCount: &conversionRequestCount)
            }
        )
        acknowledgeConvertedChange = { [weak controller] changeCount in
            controller?.acknowledgeConvertedChange(changeCount: changeCount)
        }
        controller.start()
        defer {
            controller.terminate()
            converter.terminate()
            pasteboard.clearContents()
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        pasteboard.clearContents()
        XCTAssertTrue(input.write(to: pasteboard))
        await fulfillment(of: [converted], timeout: 10)

        XCTAssertEqual(conversionRequestCount, 1)
        let outputURL = try XCTUnwrap(convertedURL)
        XCTAssertEqual(outputURL.pathExtension, outputFormat.fileExtension)
        let outputData = try Data(contentsOf: outputURL)
        let outputSource = try XCTUnwrap(CGImageSourceCreateWithData(outputData as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(outputSource) as String?, outputFormat.typeIdentifier)
        let isReferenced = await ClipboardImageConversionPasteboardCapture.referencesFile(
            outputURL,
            pasteboard: pasteboard
        )
        XCTAssertTrue(isReferenced)

        await controller.poll()
        await controller.poll()
        XCTAssertEqual(conversionRequestCount, 1)

        converter.terminate()
        await converter.waitForTerminationCleanup()
    }
}

private enum AutomaticClipboardInput {
    case data(Data, type: NSPasteboard.PasteboardType)
    case fileURL(URL)

    @MainActor
    func write(to pasteboard: NSPasteboard) -> Bool {
        switch self {
        case let .data(data, type):
            pasteboard.setData(data, forType: type)
        case let .fileURL(url):
            pasteboard.setString(url.absoluteString, forType: .fileURL)
        }
    }
}

@MainActor
private func enqueueAutomaticCapture(
    _ capture: ClipboardImageConversionCapture,
    format: ClipboardImageFormat,
    converter: ClipboardImageConversionController,
    requestCount: inout Int
) {
    guard case let .source(source) = capture else {
        XCTFail("Unexpected automatic capture result: \(capture)")
        return
    }
    requestCount += 1
    converter.convertCapturedClipboardImage(source, outputFormat: format)
}
