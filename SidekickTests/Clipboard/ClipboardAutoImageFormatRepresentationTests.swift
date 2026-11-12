import AppKit
import UniformTypeIdentifiers
import XCTest

final class ClipboardAutoImageFormatRepresentationTests: XCTestCase {
    @MainActor
    func testAutomaticSkipsWebPWhenPNGRepresentationIsAlsoPresent() async throws {
        let suiteName = "ClipboardAutoWebPWithPNGRepresentation.\(UUID().uuidString)"
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
            onCaptureResult: { _, _ in conversionRequestCount += 1 }
        )
        controller.start()
        defer {
            controller.terminate()
            pasteboard.clearContents()
            try? FileManager.default.removeItem(at: directory)
        }

        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(try pngData(width: 3, height: 2), forType: .png))
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
    }

    @MainActor
    func testAutomaticDoesNotConvertPNGRepresentationOfWebPFile() async throws {
        let suiteName = "ClipboardAutoWebPFilePNGRepresentation.\(UUID().uuidString)"
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
            onCaptureResult: { _, _ in conversionRequestCount += 1 }
        )
        controller.start()
        defer {
            controller.terminate()
            pasteboard.clearContents()
            try? FileManager.default.removeItem(at: directory)
        }

        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(sourceURL.absoluteString, forType: .fileURL))
        XCTAssertTrue(item.setData(try pngData(width: 3, height: 2), forType: .png))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        await controller.poll()
        await controller.poll()
        XCTAssertEqual(conversionRequestCount, 0)
    }

    @MainActor
    func testAutomaticDoesNotSkipUnavailableWebPRepresentation() async throws {
        let suiteName = "ClipboardAutoUnavailableWebPRepresentation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.automaticImageConversionEnabled = true
        settings.imageOutputFormat = .webP
        let pasteboard = makePasteboard()
        let directory = try temporaryDirectory()
        let sourceURL = try makeWebPFile(in: directory)
        let reader = MissingWebPRepresentationPayloadReader()
        var capture: ClipboardImageConversionCapture?
        let controller = ClipboardAutoImageConversionController(
            settings: settings,
            pasteboard: pasteboard,
            payloadReader: reader,
            onCaptureResult: { result, _ in capture = result }
        )
        controller.start()
        defer {
            controller.terminate()
            pasteboard.clearContents()
            try? FileManager.default.removeItem(at: directory)
        }

        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(try pngData(width: 3, height: 2), forType: .png))
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
        guard let capture else {
            return XCTFail("Expected the advertised WebP representation to be read")
        }
        guard case .failed = capture else {
            return XCTFail("Expected an unavailable advertised representation to be reported")
        }
        XCTAssertEqual(reader.readTypes, [UTType.webP.identifier])
    }

    @MainActor
    func testAutomaticDoesNotSkipUnavailableIndependentWebPRepresentation() async throws {
        let suiteName = "ClipboardAutoUnavailableIndependentWebPRepresentation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.automaticImageConversionEnabled = true
        settings.imageOutputFormat = .webP
        let pasteboard = makePasteboard()
        let directory = try temporaryDirectory()
        let sourceURL = try makeWebPFile(in: directory)
        let reader = MissingWebPRepresentationPayloadReader()
        var capture: ClipboardImageConversionCapture?
        let controller = ClipboardAutoImageConversionController(
            settings: settings,
            pasteboard: pasteboard,
            payloadReader: reader,
            onCaptureResult: { result, _ in capture = result }
        )
        controller.start()
        defer {
            controller.terminate()
            pasteboard.clearContents()
            try? FileManager.default.removeItem(at: directory)
        }

        let fileItem = NSPasteboardItem()
        XCTAssertTrue(fileItem.setString(sourceURL.absoluteString, forType: .fileURL))
        let imageItem = NSPasteboardItem()
        XCTAssertTrue(imageItem.setData(try pngData(width: 3, height: 2), forType: .png))
        XCTAssertTrue(
            imageItem.setData(
                try Data(contentsOf: sourceURL),
                forType: NSPasteboard.PasteboardType(UTType.webP.identifier)
            )
        )
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([fileItem, imageItem]))

        await controller.poll()
        await controller.poll()
        guard let capture else {
            return XCTFail("Expected the independent WebP representation to be read")
        }
        guard case .failed = capture else {
            return XCTFail("Expected an unavailable independent representation to be reported")
        }
        XCTAssertEqual(reader.readTypes, [UTType.webP.identifier])
    }
}

private func makeWebPFile(in directory: URL) throws -> URL {
    try ClipboardImageConversionTranscoder.convert(
        .data(try pngData(width: 3, height: 2)),
        outputDirectory: directory.appendingPathComponent("source")
    )
}

@MainActor
private final class MissingWebPRepresentationPayloadReader: PasteboardPayloadReading {
    private(set) var readTypes: [String] = []

    func readData(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int
    ) async -> PasteboardPayloadReader.Result {
        readTypes.append(type.rawValue)
        guard type != NSPasteboard.PasteboardType(UTType.webP.identifier) else {
            return .missing
        }
        guard let data = item.data(forType: type) else { return .missing }
        guard data.count <= maximumBytes else {
            return .tooLarge(byteCount: data.count)
        }
        return .data(data)
    }
}
