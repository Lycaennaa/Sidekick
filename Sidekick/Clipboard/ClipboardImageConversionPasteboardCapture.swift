import AppKit
import ImageIO
import UniformTypeIdentifiers

private enum ClipboardImageFileCaptureResult: Sendable {
    case image(Data)
    case alreadyOutputFormat
    case nonImage
    case tooLarge
    case unavailable
    case stale
}

@MainActor
enum ClipboardImageConversionPasteboardCapture {
    static func captureImage(
        from pasteboard: any PasteboardAccess,
        outputFormat: ClipboardImageFormat = .webP,
        skipAlreadyOutputFormatFiles: Bool = false,
        requireImageFileContents: Bool = false,
        fileURLReader: any PasteboardFileURLReading = SystemPasteboardFileURLReader(),
        payloadReader: any PasteboardPayloadReading = SystemPasteboardPayloadReader()
    ) async -> ClipboardImageConversionCapture {
        let sourceChangeCount = pasteboard.changeCount
        guard let items = PasteboardSnapshot.boundedItems(
            from: pasteboard,
            maximumItems: PasteboardSnapshotPolicy.maximumItems,
            rejectingOverflow: true
        ) else {
            return .unavailable
        }
        guard items.allSatisfy({
            $0.types.count <= PasteboardSnapshotPolicy.maximumTypesPerItem
        }) else {
            return .unavailable
        }
        let request = CaptureRequest(
            pasteboard: pasteboard,
            items: items,
            sourceChangeCount: sourceChangeCount,
            fileURLReader: fileURLReader,
            payloadReader: payloadReader,
            requireImageFileContents: requireImageFileContents
        )
        return await capture(
            request: request,
            outputFormat: outputFormat,
            skipAlreadyOutputFormatFiles: skipAlreadyOutputFormatFiles
        )
    }

    static func referencesFile(
        _ url: URL,
        pasteboard: any PasteboardAccess,
        maximumReadDuration: TimeInterval = PasteboardSnapshot.maximumFileURLReadDuration,
        fileURLReader: any PasteboardFileURLReading = SystemPasteboardFileURLReader()
    ) async -> Bool {
        let expectedChangeCount = pasteboard.changeCount
        guard let referencedURLs = await PasteboardSnapshot.boundedFileURLs(
            from: pasteboard,
            maximumItems: PasteboardSnapshotPolicy.maximumItems,
            maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem,
            expectedChangeCount: expectedChangeCount,
            maximumReadDuration: maximumReadDuration,
            fileURLReader: fileURLReader
        ),
        !Task.isCancelled,
        pasteboard.changeCount == expectedChangeCount else {
            return true
        }
        return referencedURLs.contains(url.standardizedFileURL)
    }
}
extension ClipboardImageConversionPasteboardCapture {
    private struct CaptureRequest {
        let pasteboard: any PasteboardAccess
        let items: [NSPasteboardItem]
        let sourceChangeCount: Int
        let fileURLReader: any PasteboardFileURLReading
        let payloadReader: any PasteboardPayloadReading
        let requireImageFileContents: Bool
    }

    private struct TypedItem {
        let itemIndex: Int
        let item: NSPasteboardItem
        let type: NSPasteboard.PasteboardType
    }

    private struct ScannedFiles {
        let fileURLs: [URL]
        let ambiguous: [URL]
        let materializedRepresentations: [PasteboardSnapshot.MaterializedRepresentation]
        let excludedImageItemIndexes: Set<Int>
    }

    private enum FileScanResult {
        case files(ScannedFiles)
        case terminal(ClipboardImageConversionCapture)
    }

    private enum SourcePreparationResult {
        case source(
            ClipboardImageSource,
            materializedRepresentations: [PasteboardSnapshot.MaterializedRepresentation]
        )
        case terminal(ClipboardImageConversionCapture)
    }

    private static func capture(
        request: CaptureRequest,
        outputFormat: ClipboardImageFormat,
        skipAlreadyOutputFormatFiles: Bool
    ) async -> ClipboardImageConversionCapture {
        switch await scanFileURLs(request) {
        case let .terminal(result):
            return result
        case let .files(scannedFiles):
            return await captureFiles(
                scannedFiles,
                request: request,
                outputFormat: outputFormat,
                skipAlreadyOutputFormatFiles: skipAlreadyOutputFormatFiles
            )
        }
    }

    private static func captureFiles(
        _ scannedFiles: ScannedFiles,
        request: CaptureRequest,
        outputFormat: ClipboardImageFormat,
        skipAlreadyOutputFormatFiles: Bool
    ) async -> ClipboardImageConversionCapture {
        let match = firstImageRepresentation(
            in: request.items,
            excluding: scannedFiles.excludedImageItemIndexes,
            preferredFormat: outputFormat
        )
        let matchIsOutputFormat = match.map {
            UTType($0.type.rawValue)?.conforms(to: outputFormat.uniformType) == true
        } ?? !scannedFiles.fileURLs.isEmpty
        if request.requireImageFileContents, !scannedFiles.fileURLs.isEmpty {
            switch await captureImageFiles(
                scannedFiles.fileURLs,
                outputFormat: outputFormat,
                skipAlreadyOutputFormatFiles: skipAlreadyOutputFormatFiles
            ) {
            case let .image(data):
                // Classify and convert these same bytes; the file may change after capture.
                return await captureSnapshot(
                    source: .data(data),
                    materializedRepresentations: scannedFiles.materializedRepresentations,
                    request: request
                )
            case .alreadyOutputFormat:
                if !matchIsOutputFormat {
                    return await capturePayload(
                        match: match,
                        fileURLs: [],
                        materializedRepresentations: scannedFiles.materializedRepresentations,
                        request: request
                    )
                }
                return await alreadyOutputFormatRepresentation(match, request: request)
            case .nonImage:
                return .noImage
            case .tooLarge:
                return .failed
            case .unavailable:
                return .unavailable
            case .stale:
                return .stale
            }
        }
        let convertibleFileURLs = skipAlreadyOutputFormatFiles
            ? scannedFiles.fileURLs.filter {
                PasteboardTypePolicy.imageType(for: $0)?.conforms(to: outputFormat.uniformType) != true
            }
            : scannedFiles.fileURLs
        if skipAlreadyOutputFormatFiles,
           convertibleFileURLs.isEmpty,
           scannedFiles.ambiguous.isEmpty,
           matchIsOutputFormat {
            return await alreadyOutputFormatRepresentation(match, request: request)

        }
        return await capturePayload(
            match: match,
            fileURLs: convertibleFileURLs + scannedFiles.ambiguous,
            materializedRepresentations: scannedFiles.materializedRepresentations,
            request: request
        )
    }
    private static func alreadyOutputFormatRepresentation(
        _ match: TypedItem?,
        request: CaptureRequest
    ) async -> ClipboardImageConversionCapture {
        guard let match else { return .alreadyOutputFormat }
        switch await request.payloadReader.readData(
            from: match.item,
            forType: match.type,
            maximumBytes: PasteboardSnapshotPolicy.maximumBytes
        ) {
        case .data: return .alreadyOutputFormat
        case .cancelled: return .stale
        case .timedOut, .unavailable: return .unavailable
        case .missing, .tooLarge, .failed: return .failed
        }
    }

    private static func firstImageRepresentation(
        in items: [NSPasteboardItem],
        excluding excludedImageItemIndexes: Set<Int>,
        preferredFormat: ClipboardImageFormat
    ) -> TypedItem? {
        let typedItems = items.enumerated().flatMap { itemIndex, item -> [TypedItem] in
            guard !excludedImageItemIndexes.contains(itemIndex) else { return [] }
            return item.types.map { type in
                TypedItem(itemIndex: itemIndex, item: item, type: type)
            }
        }
        let fallbackMatch = typedItems.first(where: { $0.type == .png })
            ?? typedItems.first(where: { $0.type == .tiff })
            ?? typedItems.first(where: { PasteboardTypePolicy.isImage($0.type) })
        guard let fallbackMatch else { return nil }
        // Multiple types on one item are alternate encodings of the same clipboard image.
        return typedItems.first(where: { candidate in
            candidate.itemIndex == fallbackMatch.itemIndex
                && UTType(candidate.type.rawValue)?.conforms(to: preferredFormat.uniformType) == true
        }) ?? fallbackMatch
    }

    private static func scanFileURLs(_ request: CaptureRequest) async -> FileScanResult {
        var fileURLs: [URL] = []
        var ambiguousFileURLs: [URL] = []
        var materializedRepresentations: [PasteboardSnapshot.MaterializedRepresentation] = []
        var excludedImageItemIndexes = Set<Int>()

        for (itemIndex, item) in request.items.enumerated() {
            guard PasteboardTypePolicy.containsFileURL(
                in: item,
                maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem
            ) else {
                continue
            }
            switch await request.fileURLReader.readFileURLData(
                from: item,
                maximumBytes: PasteboardSnapshot.maximumFileURLBytes,
                timeout: PasteboardSnapshot.maximumFileURLReadDuration
            ) {
            case let .data(data):
                guard !Task.isCancelled,
                      request.pasteboard.changeCount == request.sourceChangeCount else {
                    return .terminal(.stale)
                }
                materializedRepresentations.append(
                    .init(itemIndex: itemIndex, type: .fileURL, data: data)
                )
                let isDirectory = await isDirectoryFileURL(data)
                guard !Task.isCancelled,
                      request.pasteboard.changeCount == request.sourceChangeCount else {
                    return .terminal(.stale)
                }
                if isDirectory {
                    excludedImageItemIndexes.insert(itemIndex)
                    continue
                }
                if request.requireImageFileContents {
                    guard let fileURL = PasteboardTypePolicy.url(from: data, localOnly: true) else {
                        return .terminal(.noImage)
                    }
                    excludedImageItemIndexes.insert(itemIndex)
                    fileURLs.append(fileURL)
                } else {
                    appendFileURL(
                        from: data,
                        fileURLs: &fileURLs,
                        ambiguousFileURLs: &ambiguousFileURLs
                    )
                }
            case .missing:
                guard !request.requireImageFileContents else {
                    return .terminal(.unavailable)
                }
                materializedRepresentations.append(
                    .init(itemIndex: itemIndex, type: .fileURL, data: nil)
                )
            case .tooLarge:
                guard !request.requireImageFileContents else {
                    return .terminal(.failed)
                }
                materializedRepresentations.append(
                    .init(itemIndex: itemIndex, type: .fileURL, data: nil)
                )
            case .timedOut, .cancelled:
                return .terminal(.stale)
            case .unavailable, .failed:
                return .terminal(.unavailable)
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

    private static func isDirectoryFileURL(_ data: Data) async -> Bool {
        guard let url = PasteboardTypePolicy.url(from: data, localOnly: true) else { return false }
        if url.hasDirectoryPath { return true }
        return await isDirectory(url)
    }

    nonisolated private static func isDirectory(_ url: URL) async -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    nonisolated private static func captureImageFiles(
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
            do {
                let data = try ClipboardImageConversionFileService.sourceData(
                    fileURL,
                    maximumBytes: remainingSourceBytes,
                    isCancelled: { Task.isCancelled }
                )
                remainingSourceBytes -= data.count
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      CGImageSourceGetCount(source) > 0,
                      let sourceType = CGImageSourceGetType(source) as String?,
                      let contentType = UTType(sourceType),
                      contentType.conforms(to: .image) else {
                    return .nonImage
                }
                if skipAlreadyOutputFormatFiles,
                   contentType.conforms(to: outputFormat.uniformType) {
                    foundOutputFormatImage = true
                } else if firstConvertibleImage == nil {
                    firstConvertibleImage = data
                }
            } catch is CancellationError {
                return .stale
            } catch let error as ClipboardImageConversionError {
                switch error {
                case .invalidImage:
                    return .nonImage
                case .tooLarge:
                    return .tooLarge
                case .cannotEncode, .cannotWrite, .cannotCreateFilename:
                    return .unavailable
                }
            } catch {
                return .unavailable
            }
        }
        guard !Task.isCancelled else { return .stale }
        if let firstConvertibleImage {
            return .image(firstConvertibleImage)
        }
        return foundOutputFormatImage ? .alreadyOutputFormat : .nonImage
    }
    private static func appendFileURL(
        from data: Data,
        fileURLs: inout [URL],
        ambiguousFileURLs: inout [URL]
    ) {
        guard let url = PasteboardTypePolicy.url(from: data, localOnly: true) else { return }
        if PasteboardTypePolicy.isImage(url: url) {
            fileURLs.append(url)
        } else if UTType(filenameExtension: url.pathExtension) == nil {
            ambiguousFileURLs.append(url)
        }
    }

    private static func capturePayload(
        match: TypedItem?,
        fileURLs: [URL],
        materializedRepresentations: [PasteboardSnapshot.MaterializedRepresentation],
        request: CaptureRequest
    ) async -> ClipboardImageConversionCapture {
        switch await prepareSource(
            match: match,
            fileURLs: fileURLs,
            materializedRepresentations: materializedRepresentations,
            request: request
        ) {
        case let .terminal(result):
            return result
        case let .source(source, materializedRepresentations):
            return await captureSnapshot(
                source: source,
                materializedRepresentations: materializedRepresentations,
                request: request
            )
        }
    }

    private static func prepareSource(
        match: TypedItem?,
        fileURLs: [URL],
        materializedRepresentations: [PasteboardSnapshot.MaterializedRepresentation],
        request: CaptureRequest
    ) async -> SourcePreparationResult {
        let source: ClipboardImageSource
        var materializedRepresentations = materializedRepresentations
        if let match {
            switch await request.payloadReader.readData(
                from: match.item,
                forType: match.type,
                maximumBytes: PasteboardSnapshotPolicy.maximumBytes
            ) {
            case let .data(data):
                materializedRepresentations.append(
                    .init(itemIndex: match.itemIndex, type: match.type, data: data)
                )
                if data.count > ClipboardImageConversionPolicy.maximumSourceBytes {
                    guard !fileURLs.isEmpty else { return .terminal(.failed) }
                    source = .files(fileURLs, fallback: nil)
                } else {
                    source = fileURLs.isEmpty
                        ? .data(data)
                        : .files(fileURLs, fallback: data)
                }
            case .missing, .tooLarge:
                return .terminal(.failed)
            case .cancelled:
                return .terminal(.stale)
            case .timedOut, .failed, .unavailable:
                return .terminal(.unavailable)
            }
        } else {
            guard !fileURLs.isEmpty else { return .terminal(.noImage) }
            source = .files(fileURLs, fallback: nil)
        }
        return .source(source, materializedRepresentations: materializedRepresentations)
    }

    private static func captureSnapshot(
        source: ClipboardImageSource,
        materializedRepresentations: [PasteboardSnapshot.MaterializedRepresentation],
        request: CaptureRequest
    ) async -> ClipboardImageConversionCapture {
        guard !Task.isCancelled,
              request.pasteboard.changeCount == request.sourceChangeCount else {
            return .stale
        }
        let snapshotResult = await PasteboardSnapshot.capture(
            from: request.pasteboard,
            expectedChangeCount: request.sourceChangeCount,
            limits: PasteboardSnapshot.Limits(
                maximumBytes: PasteboardSnapshotPolicy.maximumBytes,
                maximumItems: PasteboardSnapshotPolicy.maximumItems,
                maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem
            ),
            sourceItems: request.items,
            materializedRepresentations: materializedRepresentations,
            fileURLReader: request.fileURLReader,
            payloadReader: request.payloadReader
        )
        guard !Task.isCancelled,
              request.pasteboard.changeCount == request.sourceChangeCount else {
            return .stale
        }
        switch snapshotResult {
        case let .captured(snapshot):
            return .source(
                ClipboardImageConversionCapturedSource(
                    source: source,
                    changeCount: request.sourceChangeCount,
                    snapshot: snapshot
                )
            )
        case .stale:
            return .stale
        case .failed:
            return .failed
        }
    }
}
