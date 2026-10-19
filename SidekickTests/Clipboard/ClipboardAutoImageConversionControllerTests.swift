import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class ClipboardAutoImageConversionControllerTests: XCTestCase {
    @MainActor
    func testOptInToggleOnlyProcessesNewClipboardImages() throws {
        let suiteName = "ClipboardAutoImageConversionController.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        let pasteboard = makePasteboard()
        var requestCount = 0
        let controller = ClipboardAutoImageConversionController(
            settings: settings,
            pasteboard: pasteboard,
            onImageDetected: { requestCount += 1 }
        )
        controller.start()
        defer {
            controller.terminate()
            pasteboard.clearContents()
        }

        XCTAssertTrue(pasteboard.setData(try pngData(width: 2, height: 2), forType: .png))
        controller.poll()
        controller.poll()
        XCTAssertEqual(requestCount, 0)

        settings.automaticImageConversionEnabled = true
        controller.applySettings()
        controller.poll()
        controller.poll()
        XCTAssertEqual(requestCount, 0)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(try pngData(width: 2, height: 2), forType: .png))
        controller.poll()
        controller.poll()
        XCTAssertEqual(requestCount, 1)

        settings.automaticImageConversionEnabled = false
        controller.applySettings()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(try pngData(width: 2, height: 2), forType: .png))
        controller.poll()
        controller.poll()
        XCTAssertEqual(requestCount, 1)
    }



    @MainActor
    func testFileURLDetectionDoesNotMaterializeProvider() throws {
        let suiteName = "ClipboardAutoWebPProviderProbe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.automaticImageConversionEnabled = true
        let pasteboard = makePasteboard()
        var requestCount = 0
        let controller = ClipboardAutoImageConversionController(
            settings: settings,
            pasteboard: pasteboard,
            onImageDetected: { requestCount += 1 }
        )
        controller.start()
        let provider = PasteboardSnapshotBlockingDataProvider(data: Data("file:///source".utf8))
        provider.release.signal()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.fileURL]))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        defer {
            controller.terminate()
            pasteboard.clearContents()
        }

        controller.poll()
        controller.poll()

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(provider.invocationCount, 0)
    }


    private func makeWebPFile(in directory: URL) throws -> URL {
        try ClipboardImageConversionTranscoder.convert(
            .data(try pngData(width: 3, height: 2)),
            outputDirectory: directory.appendingPathComponent("source")
        )
    }

    @MainActor
    func testAutomaticModeSkipsMixedWebPFileAndDataRepresentations() async throws {
        let suiteName = "ClipboardAutoWebPAlreadyWebP.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.automaticImageConversionEnabled = true
        let pasteboard = makePasteboard()
        let directory = try temporaryDirectory()
        let sourceURL = try makeWebPFile(in: directory)
        let outputDirectory = directory.appendingPathComponent("converted")
        let completed = expectation(description: "Already-output-format input skipped")
        var result: ClipboardImageConversionController.Result?
        var convertedCount = 0
        var messages: [String] = []
        let converter = ClipboardImageConversionController(
            pasteboard: pasteboard,
            outputDirectory: outputDirectory,
            onConverted: { _, _ in convertedCount += 1 },
            onMessage: { messages.append($0) }
        )
        let controller = ClipboardAutoImageConversionController(
            settings: settings,
            pasteboard: pasteboard,
            onImageDetected: {
                converter.convertClipboardImage(skipAlreadyOutputFormatFiles: true) {
                    result = $0
                    completed.fulfill()
                }
            }
        )
        controller.start()
        defer {
            controller.terminate()
            converter.terminate()
            pasteboard.clearContents()
            try? FileManager.default.removeItem(at: directory)
        }

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
        await fulfillment(of: [completed], timeout: 10)

        XCTAssertEqual(result, .alreadyOutputFormat)
        XCTAssertEqual(convertedCount, 0)
        XCTAssertTrue(messages.isEmpty)
        let isReferenced = await ClipboardImageConversionPasteboardCapture.referencesFile(
            sourceURL,
            pasteboard: pasteboard
        )
        XCTAssertTrue(isReferenced)

        converter.terminate()
        await converter.waitForTerminationCleanup()
        pasteboard.clearContents()
        try FileManager.default.removeItem(at: directory)
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
