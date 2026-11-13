import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ClipboardImageFileCaptureResult: Sendable {
    case image(Data)
    case alreadyOutputFormat
    case nonImage
    case tooLarge
    case unavailable
    case stale
}

@MainActor
enum ClipboardImageConversionFileCapture {
    struct ScannedFiles {
        let fileURLs: [URL]
        let ambiguous: [URL]
        let materializedRepresentations: [PasteboardSnapshot.MaterializedRepresentation]
        let excludedImageItemIndexes: Set<Int>
    }

    enum ScanResult {
        case files(ScannedFiles)
        case terminal(ClipboardImageConversionCapture)
    }

    private struct ScanRequest {
        let pasteboard: any PasteboardAccess
        let items: [NSPasteboardItem]
        let sourceChangeCount: Int
        let fileURLReader: any PasteboardFileURLReading
        let requireImageFileContents: Bool
    }

    private enum FileItemResult {
        case file(URL, PasteboardSnapshot.MaterializedRepresentation, excluded: Bool)
        case ambiguous(URL, PasteboardSnapshot.MaterializedRepresentation)
        case representation(PasteboardSnapshot.MaterializedRepresentation, excluded: Bool)
        case terminal(ClipboardImageConversionCapture)
    }

    private enum ImageFileInspectionResult: Sendable {
        case image(Data, matchesOutputFormat: Bool)
        case failure(ClipboardImageFileCaptureResult)
    }

    static func scan(
        pasteboard: any PasteboardAccess,
        items: [NSPasteboardItem],
        sourceChangeCount: Int,
        fileURLReader: any PasteboardFileURLReading,
        requireImageFileContents: Bool
    ) async -> ScanResult {
        let request = ScanRequest(
            pasteboard: pasteboard,
            items: items,
            sourceChangeCount: sourceChangeCount,
            fileURLReader: fileURLReader,
            requireImageFileContents: requireImageFileContents
        )
        var fileURLs: [URL] = []
        var ambiguousFileURLs: [URL] = []
        var materializedRepresentations: [PasteboardSnapshot.MaterializedRepresentation] = []
        var excludedImageItemIndexes = Set<Int>()

        for (itemIndex, item) in items.enumerated() {
            guard PasteboardTypePolicy.containsFileURL(
                in: item,
                maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem
            ) else {
                continue
            }
            switch await scanFileURL(item, itemIndex: itemIndex, request: request) {
            case let .file(url, representation, excluded):
                materializedRepresentations.append(representation)
                fileURLs.append(url)
                if excluded { excludedImageItemIndexes.insert(itemIndex) }
            case let .ambiguous(url, representation):
                materializedRepresentations.append(representation)
                ambiguousFileURLs.append(url)
            case let .representation(representation, excluded):
                materializedRepresentations.append(representation)
                if excluded { excludedImageItemIndexes.insert(itemIndex) }
            case let .terminal(result):
                return .terminal(result)
            }
        }
        return .files(
            ScannedFiles(
                fileURLs: fileURLs,
                ambiguous: ambiguousFileURLs,
                materializedRepresentations: materializedRepresentations,
                excludedImageItemIndexes: excludedImageItemIndexes
            )
        )
    }

    private static func scanFileURL(
        _ item: NSPasteboardItem,
        itemIndex: Int,
        request: ScanRequest
    ) async -> FileItemResult {
        switch await request.fileURLReader.readFileURLData(
            from: item,
            maximumBytes: PasteboardSnapshot.maximumFileURLBytes,
            timeout: PasteboardSnapshot.maximumFileURLReadDuration
        ) {
        case let .data(data):
            return await scanFileURLData(data, itemIndex: itemIndex, request: request)
        case .missing:
            return missingFileURLResult(itemIndex: itemIndex, request: request, tooLarge: false)
        case .tooLarge:
            return missingFileURLResult(itemIndex: itemIndex, request: request, tooLarge: true)
        case .timedOut, .cancelled:
            return .terminal(.stale)
        case .unavailable, .failed:
            return .terminal(.unavailable)
        }
    }

    private static func missingFileURLResult(
        itemIndex: Int,
        request: ScanRequest,
        tooLarge: Bool
    ) -> FileItemResult {
        guard !request.requireImageFileContents else {
            return .terminal(tooLarge ? .failed : .unavailable)
        }
        return .representation(
            .init(itemIndex: itemIndex, type: .fileURL, data: nil),
            excluded: false
        )
    }

    private static func scanFileURLData(
        _ data: Data,
        itemIndex: Int,
        request: ScanRequest
    ) async -> FileItemResult {
        guard !Task.isCancelled,
              request.pasteboard.changeCount == request.sourceChangeCount else {
            return .terminal(.stale)
        }
        let representation = PasteboardSnapshot.MaterializedRepresentation(
            itemIndex: itemIndex,
            type: .fileURL,
            data: data
        )
        let isDirectory = await isDirectoryFileURL(data)
        guard !Task.isCancelled,
              request.pasteboard.changeCount == request.sourceChangeCount else {
            return .terminal(.stale)
        }
        if isDirectory {
            return .representation(representation, excluded: true)
        }
        guard let url = PasteboardTypePolicy.url(from: data, localOnly: true) else {
            return request.requireImageFileContents
                ? .terminal(.noImage)
                : .representation(representation, excluded: false)
        }
        if request.requireImageFileContents {
            return .file(url, representation, excluded: true)
        }
        if PasteboardTypePolicy.isImage(url: url) {
            return .file(url, representation, excluded: false)
        }
        if UTType(filenameExtension: url.pathExtension) == nil {
            return .ambiguous(url, representation)
        }
        return .representation(representation, excluded: false)
    }

    private static func isDirectoryFileURL(_ data: Data) async -> Bool {
        guard let url = PasteboardTypePolicy.url(from: data, localOnly: true) else { return false }
        if url.hasDirectoryPath { return true }
        return await isDirectory(url)
    }

    nonisolated private static func isDirectory(_ url: URL) async -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    nonisolated static func captureImageFiles(
        _ fileURLs: [URL],
        outputFormat: ClipboardImageFormat,
        skipAlreadyOutputFormatFiles: Bool
    ) async -> ClipboardImageFileCaptureResult {
        var remainingSourceBytes = ClipboardImageConversionPolicy.maximumAggregateSourceBytes
        var firstConvertibleImage: Data?
        var foundOutputFormatImage = false
        for fileURL in fileURLs {
            guard !Task.isCancelled else { return .stale }
            guard remainingSourceBytes > 0 else { return .tooLarge }
            switch inspectImageFile(
                fileURL,
                maximumBytes: remainingSourceBytes,
                outputFormat: outputFormat
            ) {
            case let .image(data, matchesOutputFormat):
                remainingSourceBytes -= data.count
                if skipAlreadyOutputFormatFiles, matchesOutputFormat {
                    foundOutputFormatImage = true
                } else if firstConvertibleImage == nil {
                    firstConvertibleImage = data
                }
            case let .failure(result):
                return result
            }
        }
        guard !Task.isCancelled else { return .stale }
        if let firstConvertibleImage {
            return .image(firstConvertibleImage)
        }
        return foundOutputFormatImage ? .alreadyOutputFormat : .nonImage
    }

    nonisolated private static func inspectImageFile(
        _ fileURL: URL,
        maximumBytes: Int,
        outputFormat: ClipboardImageFormat
    ) -> ImageFileInspectionResult {
        do {
            let data = try ClipboardImageConversionFileService.sourceData(
                fileURL,
                maximumBytes: maximumBytes,
                isCancelled: { Task.isCancelled }
            )
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0,
                  let sourceType = CGImageSourceGetType(source) as String?,
                  let contentType = UTType(sourceType),
                  contentType.conforms(to: .image) else {
                return .failure(.nonImage)
            }
            return .image(data, matchesOutputFormat: contentType.conforms(to: outputFormat.uniformType))
        } catch is CancellationError {
            return .failure(.stale)
        } catch let error as ClipboardImageConversionError {
            switch error {
            case .invalidImage: return .failure(.nonImage)
            case .tooLarge: return .failure(.tooLarge)
            case .cannotEncode, .cannotWrite, .cannotCreateFilename: return .failure(.unavailable)
            }
        } catch {
            return .failure(.unavailable)
        }
    }
}
