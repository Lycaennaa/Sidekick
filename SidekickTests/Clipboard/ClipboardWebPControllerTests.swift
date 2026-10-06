import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class ClipboardWebPControllerTests: XCTestCase {
    @MainActor
    func testConvertsClipboardImageToNamedWebP() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        var messages: [String] = []
        var convertedURL: URL?
        var convertedChangeCount: Int?
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            expirationInterval: 10,
            outputDirectory: directory,
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader(),
            onConverted: { url, changeCount in
                convertedURL = url
                convertedChangeCount = changeCount
            },
            onMessage: { messages.append($0) }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        pasteboard.clearContents()
        pasteboard.setData(try pngData(width: 4, height: 3), forType: .png)

        let result = await convert(with: controller)
        guard case let .converted(url) = result else {
            return XCTFail("Expected converted WebP, got \(result)")
        }

        XCTAssertTrue(url.lastPathComponent.range(
            of: "^[A-Za-z0-9]{7}\\.webp$",
            options: .regularExpression
        ) != nil)
        XCTAssertEqual(ClipboardWebPConfiguration.quality, 0.75)
        XCTAssertEqual(
            ClipboardWebPConfiguration.maximumOutputBytes,
            ClipboardImageDecoder.maximumSourceBytes
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let isReferenced = await ClipboardWebPPasteboardCapture.referencesFile(
            url,
            pasteboard: pasteboard,
            fileURLReader: InlinePasteboardFileURLReader()
        )
        XCTAssertTrue(isReferenced)
        XCTAssertEqual(convertedURL, url)
        XCTAssertEqual(convertedChangeCount, pasteboard.changeCount)
        XCTAssertTrue(messages.isEmpty)

        let data = try Data(contentsOf: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.webP.identifier)
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 4)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 3)
    }
    @MainActor
    func testDefaultProductionDependenciesConvertNamedPasteboardImage() async throws {
        let pasteboard = makePasteboard()
        let directory = try temporaryDirectory()
        var messages: [String] = []
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            outputDirectory: directory,
            onMessage: { messages.append($0) }
        )
        defer {
            controller.terminate()
            pasteboard.clearContents()
            try? FileManager.default.removeItem(at: directory)
        }

        pasteboard.clearContents()
        guard let imageData = try? pngData(width: 4, height: 3),
              pasteboard.setData(imageData, forType: .png) else {
            controller.terminate()
            await controller.waitForTerminationCleanup()
            return XCTFail("Unable to install the named pasteboard image")
        }

        let result = await convert(with: controller)
        guard case let .converted(url) = result else {
            controller.terminate()
            await controller.waitForTerminationCleanup()
            return XCTFail("Expected default WebP conversion, got \(result)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let isReferenced = await ClipboardWebPPasteboardCapture.referencesFile(
            url,
            pasteboard: pasteboard
        )
        XCTAssertTrue(isReferenced)
        XCTAssertTrue(messages.isEmpty)

        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                  as? [CFString: Any] else {
            controller.terminate()
            await controller.waitForTerminationCleanup()
            return XCTFail("Expected readable WebP output")
        }
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.webP.identifier)
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 4)
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 3)

        controller.terminate()
        await controller.waitForTerminationCleanup()
        for _ in 0..<64 {
            await Task.yield()
        }
    }

    @MainActor
    func testNativeMalformedPayloadIsReportedWithoutInstallation() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        var messages: [String] = []
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            outputDirectory: directory,
            onMessage: { messages.append($0) }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Data([0x00]), forType: .png))

        let result = await convert(with: controller)

        XCTAssertEqual(result, .noImage)
        XCTAssertEqual(messages, ["No image to convert"])
        XCTAssertEqual(pasteboard.data(forType: .png), Data([0x00]))
    }

    @MainActor
    func testNoImageLeavesClipboardUnchangedAndShowsToast() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        var messages: [String] = []
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            outputDirectory: directory,
            onMessage: { messages.append($0) }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        pasteboard.clearContents()
        pasteboard.setString("not an image", forType: .string)

        let result = await convert(with: controller)
        XCTAssertEqual(result, .noImage)
        XCTAssertEqual(pasteboard.string(forType: .string), "not an image")
        XCTAssertEqual(messages, ["No image to convert"])
    }
    @MainActor
    func testOversizedPasteboardImageIsRejectedAtCapture() async {
        let pasteboard = makeTransactionalPasteboard()
        pasteboard.clearContents()
        pasteboard.setData(
            Data(repeating: 0x00, count: ClipboardWebPConfiguration.maximumSourceBytes + 1),
            forType: .png
        )

        guard case .failed = await ClipboardWebPPasteboardCapture.captureImage(
            from: pasteboard,
            payloadReader: InlinePasteboardPayloadReader()
        ) else {
            return XCTFail("Expected oversized pasteboard image to be rejected")
        }
    }
}

extension ClipboardWebPControllerTests {
    @MainActor
    func testCancelledConversionDoesNotShowFailureMessage() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        var messages: [String] = []
        let worker = ClipboardWebPWorker(convert: { _, _, _ in
            throw CancellationError()
        })
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            outputDirectory: directory,
            worker: worker,
            payloadReader: InlinePasteboardPayloadReader(),
            onMessage: { messages.append($0) }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        pasteboard.clearContents()
        pasteboard.setData(try pngData(width: 2, height: 2), forType: .png)

        let result = await convert(with: controller)

        XCTAssertEqual(result, .cancelled)
        XCTAssertTrue(messages.isEmpty)
        XCTAssertNotNil(pasteboard.data(forType: .png))
    }

    @MainActor
    func testConversionFailureStillShowsFailureMessage() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        var messages: [String] = []
        let worker = ClipboardWebPWorker(convert: { _, _, _ in
            throw ClipboardWebPConversionError.cannotEncode
        })
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            outputDirectory: directory,
            worker: worker,
            payloadReader: InlinePasteboardPayloadReader(),
            onMessage: { messages.append($0) }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        pasteboard.clearContents()
        pasteboard.setData(try pngData(width: 2, height: 2), forType: .png)

        let result = await convert(with: controller)

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(messages, ["Couldn’t convert image to WebP"])
    }

    @MainActor
    func testWorkerMapsUnexpectedErrorToTypedFailure() async {
        let worker = ClipboardWebPWorker(convert: { _, _ in
            throw NSError(
                domain: "ClipboardWebPTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Synthetic conversion failure"]
            )
        })
        let completion = expectation(description: "Worker completion")
        var result: ClipboardWebPWorker.Result?

        worker.enqueue(
            source: .data(Data()),
            outputDirectory: URL(fileURLWithPath: "unused"),
            cleanup: { _ in },
            completion: { value in
                result = value
                completion.fulfill()
            }
        )

        await fulfillment(of: [completion], timeout: 5)

        guard case let .failure(failure) = result else {
            return XCTFail("Expected typed conversion failure")
        }
        XCTAssertEqual(failure, .unexpected("Synthetic conversion failure"))
    }

    @MainActor
    func testConvertsExtensionlessImageFile() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let sourceURL = directory.appendingPathComponent("image")
        try pngData(width: 3, height: 2).write(to: sourceURL)
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            expirationInterval: 10,
            outputDirectory: directory.appendingPathComponent("output"),
             fileURLReader: InlinePasteboardFileURLReader(),
            onMessage: { _ in }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        pasteboard.clearContents()
        pasteboard.setString(sourceURL.absoluteString, forType: .fileURL)

        guard case .converted = await convert(with: controller) else {
            return XCTFail("Expected extensionless image file conversion")
        }
    }

    @MainActor
    func testFindsExtensionlessImageAfterNonImageFile() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let textURL = directory.appendingPathComponent("first")
        let imageURL = directory.appendingPathComponent("second")
        try Data("not an image".utf8).write(to: textURL)
        try pngData(width: 3, height: 2).write(to: imageURL)
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            expirationInterval: 10,
            outputDirectory: directory.appendingPathComponent("output"),
            fileURLReader: InlinePasteboardFileURLReader(),
            onMessage: { _ in }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        let textItem = NSPasteboardItem()
        textItem.setString(textURL.absoluteString, forType: .fileURL)
        let imageItem = NSPasteboardItem()
        imageItem.setString(imageURL.absoluteString, forType: .fileURL)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([textItem, imageItem]))

        guard case .converted = await convert(with: controller) else {
            return XCTFail("Expected later extensionless image file conversion")
        }
    }

    @MainActor
    func testFolderClipboardShowsNoImageMessage() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        var messages: [String] = []
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            outputDirectory: directory.appendingPathComponent("output"),
            fileURLReader: InlinePasteboardFileURLReader(),
            onMessage: { messages.append($0) }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        pasteboard.clearContents()
        pasteboard.setString(directory.absoluteString, forType: .fileURL)

        let result = await convert(with: controller)
        XCTAssertEqual(result, .noImage)
        XCTAssertEqual(messages, ["No image to convert"])
    }

    @MainActor
    func testFallsBackToImageDataWhenFileURLCannotBeRead() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            expirationInterval: 10,
            outputDirectory: directory,
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader(),
            onMessage: { _ in }
        )
        defer {
            controller.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        let missingFileItem = NSPasteboardItem()
        let missingURL = directory.appendingPathComponent("missing.png")
        missingFileItem.setString(missingURL.absoluteString, forType: .fileURL)
        let imageItem = NSPasteboardItem()
        imageItem.setData(try pngData(width: 3, height: 2), forType: .png)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([missingFileItem, imageItem]))

        guard case .converted = await convert(with: controller) else {
            return XCTFail("Expected image-data fallback conversion")
        }
    }

    @MainActor
    func testRapidSecondRequestCompletesCancelledFirstRequest() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let controller = ClipboardWebPController(
            pasteboard: pasteboard,
            expirationInterval: 10,
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
        let firstCompletion = expectation(description: "First conversion completion")
        var firstResult: ClipboardWebPController.Result?
        controller.convertClipboardImage { result in
            firstResult = result
            firstCompletion.fulfill()
        }

        pasteboard.clearContents()
        pasteboard.setString("not an image", forType: .string)
        let secondResult = await convert(with: controller)
        XCTAssertEqual(secondResult, .noImage)
        await fulfillment(of: [firstCompletion], timeout: 5)
        XCTAssertEqual(firstResult, .stale)
    }

 }
