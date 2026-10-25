import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class ClipboardAutoImageConversionControllerTests: XCTestCase {
    @MainActor
    func testOptInToggleOnlyProcessesNewClipboardImages() async throws {
        let suiteName = "ClipboardAutoImageConversionController.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let pasteboard = makePasteboard()
        var requestCount = 0
        let controller = ClipboardAutoImageConversionController(
            settings: settings,
            pasteboard: pasteboard,
            onImageDetected: { _, _ in requestCount += 1 }
        )
        controller.start()
        defer {
            controller.terminate()
            pasteboard.clearContents()
        }

        XCTAssertTrue(pasteboard.setData(try pngData(width: 2, height: 2), forType: .png))
        await controller.poll()
        await controller.poll()
        XCTAssertEqual(requestCount, 0)

        settings.automaticImageConversionEnabled = true
        controller.applySettings()
        await controller.poll()
        await controller.poll()
        XCTAssertEqual(requestCount, 0)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(try pngData(width: 2, height: 2), forType: .png))
        await controller.poll()
        await controller.poll()
        XCTAssertEqual(requestCount, 1)

        settings.automaticImageConversionEnabled = false
        controller.applySettings()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(try pngData(width: 2, height: 2), forType: .png))
        await controller.poll()
        await controller.poll()
        XCTAssertEqual(requestCount, 1)
    }
    @MainActor
    func testManualConversionCancelsDetectionAndKeepsNewClipboardData() async throws {
        let suiteName = "ClipboardAutoDetectionRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.automaticImageConversionEnabled = true
        let pasteboard = makePasteboard()
        let newerImageData = try pngData(width: 5, height: 4)
        let sourceItem = NSPasteboardItem()
        XCTAssertTrue(sourceItem.setString("file:///source", forType: .fileURL))
        let reader = BlockingAutomaticFileURLReader()
        var conversionRequestCount = 0
        let controller = ClipboardAutoImageConversionController(
            settings: settings,
            pasteboard: pasteboard,
            fileURLReader: reader,
            onImageDetected: { _, _ in conversionRequestCount += 1 }
        )
        controller.start()
        defer {
            reader.release(with: .data(Data("file:///source".utf8)))
            controller.terminate()
            pasteboard.clearContents()
        }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([sourceItem]))
        await controller.poll()
        let detectionTask = Task { @MainActor in await controller.poll() }
        await fulfillment(of: [reader.readStarted], timeout: 5)

        controller.cancelPendingDetection()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(newerImageData, forType: .png))
        reader.release(with: .data(Data("file:///source".utf8)))
        await detectionTask.value

        XCTAssertEqual(conversionRequestCount, 0)
        XCTAssertEqual(pasteboard.data(forType: .png), newerImageData)
    }

    private func makeWebPFile(in directory: URL) throws -> URL {
        try ClipboardImageConversionTranscoder.convert(
            .data(try pngData(width: 3, height: 2)),
            outputDirectory: directory.appendingPathComponent("source")
        )
    }

    @MainActor
    func testAutomaticModeSkipsAlreadyOutputFormatDataAndFiles() async throws {
        let suiteName = "ClipboardAutoWebPAlreadyWebP.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.automaticImageConversionEnabled = true
        settings.imageOutputFormat = .webP
        let pasteboard = makePasteboard()
        let directory = try temporaryDirectory()
        let sourceURL = try makeWebPFile(in: directory)
        var conversionRequestCount = 0
        let controller = ClipboardAutoImageConversionController(
            settings: settings,
            pasteboard: pasteboard,
            onImageDetected: { _, _ in conversionRequestCount += 1 }
        )
        controller.start()
        defer {
            controller.terminate()
            pasteboard.clearContents()
            try? FileManager.default.removeItem(at: directory)
        }

        pasteboard.clearContents()
        XCTAssertTrue(
            pasteboard.setData(
                try Data(contentsOf: sourceURL),
                forType: NSPasteboard.PasteboardType(UTType.webP.identifier)
            )
        )
        await controller.poll()
        await controller.poll()
        XCTAssertEqual(conversionRequestCount, 0)

        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(sourceURL.absoluteString, forType: .fileURL))
        XCTAssertTrue(
            item.setData(
                try Data(contentsOf: sourceURL),
                forType: NSPasteboard.PasteboardType(UTType.webP.identifier)
            )
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        await controller.poll()
        await controller.poll()

        XCTAssertEqual(conversionRequestCount, 0)
        let isReferenced = await ClipboardImageConversionPasteboardCapture.referencesFile(
            sourceURL,
            pasteboard: pasteboard
        )
        XCTAssertTrue(isReferenced)
    }
    func testNoImageMessageIsSuppressedOnlyForAutomaticConversion() {
        var ownership = ClipboardImageConversionOwnership()
        let generation: UInt64 = 17
        ownership.beginAutomaticConversion(generation: generation)

        XCTAssertFalse(ownership.shouldPresentNoImageMessage(utilityGeneration: generation))
        ownership.completeAutomaticConversion(generation: generation)
        XCTAssertTrue(ownership.shouldPresentNoImageMessage(utilityGeneration: generation))
    }
    func testManualDisabledCancellationRunsWithoutAutomaticOwner() {
        let ownership = ClipboardImageConversionOwnership()
        var cancellationCount = 0

        ownership.cancelPendingUtilityOperationIfNotAutomatic(utilityGeneration: 17) {
            cancellationCount += 1
        }

        XCTAssertEqual(cancellationCount, 1)
    }

    @MainActor
    func testToastSettingChangeDoesNotCancelAutomaticWebPConversion() async throws {
        let suiteName = "ClipboardAutoWebPSettingsRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.imageConversionEnabled = false
        var ownership = ClipboardImageConversionOwnership()
        let utilityGeneration: UInt64 = 17
        ownership.beginAutomaticConversion(generation: utilityGeneration)

        let pasteboard = makePasteboard()
        let imageData = try pngData(width: 4, height: 3)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(imageData, forType: .png))
        let reader = BlockingAutoWebPPayloadReader()
        let directory = try temporaryDirectory()
        let converted = expectation(description: "Automatic conversion completed")
        var convertedURL: URL?
        let converter = ClipboardImageConversionController(
            pasteboard: pasteboard,
            outputDirectory: directory,
            payloadReader: reader,
            onConverted: { url, _ in
                convertedURL = url
                converted.fulfill()
            },
            onMessage: { _ in }
        )
        var cancellationCount = 0
        settings.onChange = {
            ownership.cancelPendingUtilityOperationIfNotAutomatic(
                utilityGeneration: utilityGeneration,
                cancel: {
                    cancellationCount += 1
                    converter.cancelPendingConversion()
                }
            )
        }
        defer {
            reader.release(with: imageData)
            converter.terminate()
            pasteboard.clearContents()
            try? FileManager.default.removeItem(at: directory)
        }

        converter.convertClipboardImage(skipAlreadyOutputFormatFiles: true)
        await fulfillment(of: [reader.readStarted], timeout: 5)
        settings.clipboardToastEnabled = false
        XCTAssertEqual(cancellationCount, 0)
        reader.release(with: imageData)
        await fulfillment(of: [converted], timeout: 10)

        let url = try XCTUnwrap(convertedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let isReferenced = await ClipboardImageConversionPasteboardCapture.referencesFile(
            url,
            pasteboard: pasteboard
        )
        XCTAssertTrue(isReferenced)
        ownership.completeAutomaticConversion(generation: utilityGeneration)

        converter.terminate()
        await converter.waitForTerminationCleanup()
        pasteboard.clearContents()
        try FileManager.default.removeItem(at: directory)
    }

}

@MainActor
private final class BlockingAutoWebPPayloadReader: PasteboardPayloadReading {
    let readStarted = XCTestExpectation(description: "Automatic WebP payload read started")
    private var continuation: CheckedContinuation<PasteboardPayloadReader.Result, Never>?
    private var releasedResult: PasteboardPayloadReader.Result?
    private var didStartRead = false

    func readData(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int
    ) async -> PasteboardPayloadReader.Result {
        if !didStartRead {
            didStartRead = true
            readStarted.fulfill()
        }
        if let releasedResult { return releasedResult }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(with data: Data) {
        let result = PasteboardPayloadReader.Result.data(data)
        releasedResult = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}
@MainActor
private final class BlockingAutomaticFileURLReader: PasteboardFileURLReading {
    let readStarted = XCTestExpectation(description: "Automatic file URL read started")
    private var continuation: CheckedContinuation<PasteboardFileURLReadResult, Never>?

    func readFileURLData(
        from item: NSPasteboardItem,
        maximumBytes: Int,
        timeout: TimeInterval
    ) async -> PasteboardFileURLReadResult {
        readStarted.fulfill()
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(with result: PasteboardFileURLReadResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
