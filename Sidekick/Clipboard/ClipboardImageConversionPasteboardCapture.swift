import AppKit
import ImageIO
import UniformTypeIdentifiers

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
        switch await ClipboardImageConversionFileCapture.scan(
            pasteboard: request.pasteboard,
            items: request.items,
            sourceChangeCount: request.sourceChangeCount,
            fileURLReader: request.fileURLReader,
            requireImageFileContents: request.requireImageFileContents
        ) {
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
        _ scannedFiles: ClipboardImageConversionFileCapture.ScannedFiles,
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
            switch await ClipboardImageConversionFileCapture.captureImageFiles(
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
