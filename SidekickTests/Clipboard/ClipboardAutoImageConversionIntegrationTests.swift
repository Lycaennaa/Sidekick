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
        let folderItem = NSPasteboardItem()
        XCTAssertTrue(folderItem.setString(folderURL.absoluteString, forType: .fileURL))
        XCTAssertTrue(folderItem.setData(try pngData(width: 4, height: 3), forType: .png))
        XCTAssertTrue(pasteboard.writeObjects([folderItem]))
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
    func testAutomaticConvertsCopiedNSImageToWebP() async throws {
        let image = try XCTUnwrap(NSImage(data: pngData(width: 4, height: 3)))
        try await assertAutomaticReencode(
            input: .image(image),
            outputFormat: .webP
        )
    }

    @MainActor
    func testAutomaticConvertsLazilyProvidedPNGToWebPOnce() async throws {
        let provider = LazyImagePasteboardProvider(data: try pngData(width: 4, height: 3))
        try await assertAutomaticReencode(
            input: .lazyImage(provider),
            outputFormat: .webP
        )
        XCTAssertEqual(provider.requestCount, 1)
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
        guard ClipboardAVIFEncoder.isAvailable else {
            throw XCTSkip("ImageIO does not provide an AVIF writer on this macOS version.")
        }
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
            onConverted: { url, changeCount, _ in
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
        try await assertAutomaticOutput(
            outputURL,
            expectedFormat: outputFormat,
            pasteboard: pasteboard
        )

        await controller.poll()
        await controller.poll()
        XCTAssertEqual(conversionRequestCount, 1)

        converter.terminate()
        await converter.waitForTerminationCleanup()
    }

    @MainActor
    private func assertAutomaticOutput(
        _ outputURL: URL,
        expectedFormat: ClipboardImageFormat,
        pasteboard: NSPasteboard
    ) async throws {
        XCTAssertEqual(outputURL.pathExtension, expectedFormat.fileExtension)
        let outputData = try Data(contentsOf: outputURL)
        let outputSource = try XCTUnwrap(CGImageSourceCreateWithData(outputData as CFData, nil))
        XCTAssertEqual(
            CGImageSourceGetType(outputSource) as String?,
            expectedFormat.typeIdentifier
        )
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
        let clipboardData = try XCTUnwrap(
            pasteboard.data(
                forType: NSPasteboard.PasteboardType(expectedFormat.typeIdentifier)
            )
        )
        XCTAssertEqual(clipboardData, outputData)
        let isReferenced = await ClipboardImageConversionPasteboardCapture.referencesFile(
            outputURL,
            pasteboard: pasteboard
        )
        XCTAssertTrue(isReferenced)
        let exactFileURL = await PasteboardSnapshot.exactFileURL(
            from: pasteboard,
            maximumItems: PasteboardSnapshotPolicy.maximumItems,
            maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem,
            expectedChangeCount: pasteboard.changeCount
        )
        XCTAssertEqual(exactFileURL, outputURL.standardizedFileURL)
    }
}

private enum AutomaticClipboardInput {
    case data(Data, type: NSPasteboard.PasteboardType)
    case fileURL(URL)
    case image(NSImage)
    case lazyImage(LazyImagePasteboardProvider)

    @MainActor
    func write(to pasteboard: NSPasteboard) -> Bool {
        switch self {
        case let .data(data, type):
            return pasteboard.setData(data, forType: type)
        case let .fileURL(url):
            return pasteboard.setString(url.absoluteString, forType: .fileURL)
        case let .image(image):
            return pasteboard.writeObjects([image])
        case let .lazyImage(provider):
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [.png])
            return pasteboard.writeObjects([item])
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

private final class LazyImagePasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    let data: Data
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    init(data: Data) {
        self.data = data
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        lock.lock()
        requests += 1
        lock.unlock()
        item.setData(data, forType: type)
    }
}
