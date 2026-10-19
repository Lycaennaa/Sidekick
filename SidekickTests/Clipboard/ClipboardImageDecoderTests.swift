import AppKit
import Darwin
import ImageIO
import XCTest

@MainActor
final class ClipboardImageDecoderTests: XCTestCase {
    func testImageDecoderCreatesBoundedThumbnailAndMetadata() throws {
        let data = try pngData(width: 4, height: 3)
        let result = try XCTUnwrap(
            ClipboardImageDecoder.decode(
                ClipboardImageEnrichmentRequest(
                    generation: 9,
                    data: data,
                    typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
                )
            )
        )

        XCTAssertEqual(result.generation, 9)
        XCTAssertEqual(result.imageFooter, "4 × 3 • PNG • \(byteCountLabel(data.count))")
        XCTAssertLessThanOrEqual(result.thumbnail.width, ClipboardImageDecoder.maximumThumbnailPixelSize)
        XCTAssertLessThanOrEqual(result.thumbnail.height, ClipboardImageDecoder.maximumThumbnailPixelSize)
    }
    func testImageDecoderReportsDeclaredAndEncodedFormatsWhenTheyDisagree() async throws {
        let sourcePNG = try pngData(width: 4, height: 3)
        let sourceWebP = try ClipboardImageEncoder.encode(
            sourcePNG,
            format: .webP,
            isCancelled: { false }
        )
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(sourceWebP as CFData, nil))
        XCTAssertEqual(
            CGImageSourceGetType(imageSource) as String?,
            ClipboardImageFormat.webP.typeIdentifier
        )

        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipboardImageDecoderTests.\(UUID().uuidString)")
        )
        defer { pasteboard.clearContents() }
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(sourceWebP, forType: .png))
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let analysis = await ClipboardPayloadClassifier.analyze(
            items: try XCTUnwrap(pasteboard.pasteboardItems),
            generation: 10
        )
        let request = try XCTUnwrap(imageEnrichment(from: analysis.classification))
        XCTAssertEqual(request.typeIdentifier, NSPasteboard.PasteboardType.png.rawValue)
        let result = try XCTUnwrap(ClipboardImageDecoder.decode(request))
        XCTAssertEqual(
            result.imageFooter,
            "4 × 3 • PNG type, WEBP data • \(byteCountLabel(sourceWebP.count))"
        )
    }

    func testRealPasteboardPNGUsesPNGFooter() async throws {
        let data = try pngData(width: 4, height: 3)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipboardImageDecoderTests.\(UUID().uuidString)")
        )
        defer { pasteboard.clearContents() }
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(data, forType: .png))
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let analysis = await ClipboardPayloadClassifier.analyze(
            items: try XCTUnwrap(pasteboard.pasteboardItems),
            generation: 11
        )
        let request = try XCTUnwrap(imageEnrichment(from: analysis.classification))
        XCTAssertEqual(request.typeIdentifier, NSPasteboard.PasteboardType.png.rawValue)
        let result = try XCTUnwrap(ClipboardImageDecoder.decode(request))
        XCTAssertEqual(result.imageFooter, "4 × 3 • PNG • \(byteCountLabel(data.count))")
    }


    func testImageDecoderRejectsMalformedAndCancelledWork() {
        let request = ClipboardImageEnrichmentRequest(
            generation: 1,
            data: Data([0x00, 0x01]),
            typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
        )

        XCTAssertNil(ClipboardImageDecoder.decode(request))
        XCTAssertNil(ClipboardImageDecoder.decode(request, isCancelled: { true }))
    }
    func testImageDecoderRejectsOversizedDataBeforeImageIO() {
        let request = ClipboardImageEnrichmentRequest(
            generation: 2,
            data: Data(repeating: 0x00, count: ClipboardImageDecoder.maximumSourceBytes + 1),
            typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
        )

        XCTAssertNil(ClipboardImageDecoder.decode(request))
    }

    func testFinderImageFileRequestsAndDecodesThumbnail() async throws {
        let fileURL = try temporaryFileURL(extension: "png")
        try pngData(width: 5, height: 2).write(to: fileURL)
        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [fileItem(fileURL.path)],
            generation: 12,
            fileURLReader: InlinePasteboardFileURLReader()
        )
        let request = try XCTUnwrap(imageEnrichment(from: analysis.classification))
        let enrichment = try XCTUnwrap(ClipboardImageDecoder.decode(request))

        let model = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(model.presentationStyle, .files)
        XCTAssertEqual(model.summary, "Copied image.png")
        XCTAssertEqual(request.kind, .localFile)
        XCTAssertEqual(enrichment.kind, .localFile)
    }

    func testFinderImageFileAboveLimitIsNotReadForThumbnail() async throws {
        let fileURL = try temporaryFileURL(extension: "png")
        XCTAssertTrue(FileManager.default.createFile(atPath: fileURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: UInt64(ClipboardImageDecoder.maximumSourceBytes + 1))
        try handle.close()
        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [fileItem(fileURL.path)],
            generation: 13,
            fileURLReader: InlinePasteboardFileURLReader()
        )

        let request = try XCTUnwrap(imageEnrichment(from: analysis.classification))
        XCTAssertNil(ClipboardImageDecoder.decode(request))
    }

    func testFinderImagePathReplacedByFIFOIsRejectedWithoutBlocking() async throws {
        let fileURL = try temporaryFileURL(extension: "png")
        XCTAssertEqual(fileURL.path.withCString { mkfifo($0, 0o600) }, 0)
        let analysis = await ClipboardPayloadClassifier.analyze(
            items: [fileItem(fileURL.path)],
            generation: 14,
            fileURLReader: InlinePasteboardFileURLReader()
        )

        let request = try XCTUnwrap(imageEnrichment(from: analysis.classification))
        XCTAssertNil(ClipboardImageDecoder.decode(request))
    }

    func testImageGateRejectsPayloadAboveLimit() {
        XCTAssertTrue(
            ClipboardPayloadClassifier.shouldEnrichImage(
                byteCount: ClipboardPayloadClassifier.maximumImageBytes
            )
        )
        XCTAssertFalse(
            ClipboardPayloadClassifier.shouldEnrichImage(
                byteCount: ClipboardPayloadClassifier.maximumImageBytes + 1
            )
        )
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 32
            )
        )
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func temporaryFileURL(extension pathExtension: String) throws -> URL {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".kilo-tmp/ClipboardPayloadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("image.\(pathExtension)")
    }

    private func fileItem(_ path: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        return item
    }
    private func imageEnrichment(
        from classification: ClipboardPayloadClassification
    ) -> ClipboardImageEnrichmentRequest? {
        switch classification {
        case let .files(_, _, _, _, _, _, request):
            return request
        case let .image(_, _, request, _):
            return request
        case .text, .generic, .unavailable:
            return nil
        }
    }

}
