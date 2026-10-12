import AppKit
import UniformTypeIdentifiers

@MainActor
enum ClipboardImageConversionPasteboardCapture {
    static func captureImage(
        from pasteboard: any PasteboardAccess,
        outputFormat: ClipboardImageFormat = .webP,
        skipAlreadyOutputFormatFiles: Bool = false,
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
            payloadReader: payloadReader
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
    }

    private struct TypedItem {
        let itemIndex: Int
        let item: NSPasteboardItem
        let type: NSPasteboard.PasteboardType
    }

    private struct ScannedFiles {
        let image: [URL]
        let ambiguous: [URL]
        let materializedRepresentations: [PasteboardSnapshot.MaterializedRepresentation]
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
        let match = firstImageRepresentation(in: request.items)
        let convertibleFileURLs = skipAlreadyOutputFormatFiles
            ? scannedFiles.image.filter {
                PasteboardTypePolicy.imageType(for: $0)?.conforms(to: outputFormat.uniformType) != true
            }
            : scannedFiles.image
        let matchIsOutputFormat = match.map {
            UTType($0.type.rawValue)?.conforms(to: outputFormat.uniformType) == true
        } ?? true
        if skipAlreadyOutputFormatFiles,
           !scannedFiles.image.isEmpty,
           convertibleFileURLs.isEmpty,
           scannedFiles.ambiguous.isEmpty,
           matchIsOutputFormat {
            return .alreadyOutputFormat
        }
        return await capturePayload(
            match: match,
            fileURLs: convertibleFileURLs + scannedFiles.ambiguous,
            materializedRepresentations: scannedFiles.materializedRepresentations,
            request: request
        )
    }

    private static func firstImageRepresentation(in items: [NSPasteboardItem]) -> TypedItem? {
        let typedItems = items.enumerated().flatMap { itemIndex, item in
            item.types.map { type in
                TypedItem(itemIndex: itemIndex, item: item, type: type)
            }
        }
        for preferredType in [NSPasteboard.PasteboardType.png, .tiff] {
            if let match = typedItems.first(where: { $0.type == preferredType }) {
                return match
            }
        }
        return typedItems.first(where: { PasteboardTypePolicy.isImage($0.type) })
    }

    private static func scanFileURLs(_ request: CaptureRequest) async -> FileScanResult {
        var imageFileURLs: [URL] = []
        var ambiguousFileURLs: [URL] = []
        var materializedRepresentations: [PasteboardSnapshot.MaterializedRepresentation] = []

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
                appendFileURL(
                    from: data,
                    imageFileURLs: &imageFileURLs,
                    ambiguousFileURLs: &ambiguousFileURLs
                )
            case .missing, .tooLarge:
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
                image: imageFileURLs,
                ambiguous: ambiguousFileURLs,
                materializedRepresentations: materializedRepresentations
            )
        )
    }

    private static func appendFileURL(
        from data: Data,
        imageFileURLs: inout [URL],
        ambiguousFileURLs: inout [URL]
    ) {
        guard let url = PasteboardTypePolicy.url(from: data, localOnly: true) else { return }
        if PasteboardTypePolicy.isImage(url: url) {
            imageFileURLs.append(url)
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
