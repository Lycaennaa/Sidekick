import AppKit
import UniformTypeIdentifiers

@MainActor
enum ClipboardWebPPasteboardCapture {
    static func captureImage(
        from pasteboard: any PasteboardAccess,
        skipAlreadyWebPFiles: Bool = false,
        fileURLReader: any PasteboardFileURLReading = SystemPasteboardFileURLReader(),
        payloadReader: any PasteboardPayloadReading = SystemPasteboardPayloadReader()
    ) async -> ClipboardWebPCapture {
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

        switch await scanFileURLs(
            in: items,
            pasteboard: pasteboard,
            sourceChangeCount: sourceChangeCount,
            fileURLReader: fileURLReader
        ) {
        case let .terminal(result):
            return result
        case let .files(imageFileURLs, ambiguousFileURLs):
            let typedItems = items.flatMap { item in
                item.types.map { (item, $0) }
            }
            let preferredTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
            let match = preferredTypes.lazy.compactMap { preferred in
                typedItems.first(where: { _, type in type == preferred })
            }.first ?? typedItems.first(where: { _, type in
                PasteboardTypePolicy.isImage(type)
            })
            let convertibleFileURLs = skipAlreadyWebPFiles
                ? imageFileURLs.filter {
                    PasteboardTypePolicy.imageType(for: $0)?.conforms(to: .webP) != true
                }
                : imageFileURLs
            let matchIsWebP: Bool
            if let match {
                matchIsWebP = UTType(match.1.rawValue)?.conforms(to: .webP) == true
            } else {
                matchIsWebP = true
            }
            if skipAlreadyWebPFiles,
               !imageFileURLs.isEmpty,
               convertibleFileURLs.isEmpty,
               ambiguousFileURLs.isEmpty,
               matchIsWebP {
                return .alreadyWebP
            }
            return await capturePayload(
                match: match,
                fileURLs: convertibleFileURLs + ambiguousFileURLs,
                pasteboard: pasteboard,
                sourceChangeCount: sourceChangeCount,
                payloadReader: payloadReader
            )
        }
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
extension ClipboardWebPPasteboardCapture {
    private enum FileScanResult {
        case files(image: [URL], ambiguous: [URL])
        case terminal(ClipboardWebPCapture)
    }

    private static func scanFileURLs(
        in items: [NSPasteboardItem],
        pasteboard: any PasteboardAccess,
        sourceChangeCount: Int,
        fileURLReader: any PasteboardFileURLReading
    ) async -> FileScanResult {
        var imageFileURLs: [URL] = []
        var ambiguousFileURLs: [URL] = []

        for item in items {
            guard PasteboardTypePolicy.containsFileURL(
                in: item,
                maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem
            ) else {
                continue
            }
            switch await fileURLReader.readFileURLData(
                from: item,
                maximumBytes: PasteboardSnapshot.maximumFileURLBytes,
                timeout: PasteboardSnapshot.maximumFileURLReadDuration
            ) {
            case let .data(data):
                guard !Task.isCancelled,
                      pasteboard.changeCount == sourceChangeCount else {
                    return .terminal(.stale)
                }
                appendFileURL(
                    from: data,
                    imageFileURLs: &imageFileURLs,
                    ambiguousFileURLs: &ambiguousFileURLs
                )
            case .missing, .tooLarge:
                continue
            case .timedOut, .cancelled:
                return .terminal(.stale)
            case .unavailable, .failed:
                return .terminal(.unavailable)
            }
        }
        return .files(image: imageFileURLs, ambiguous: ambiguousFileURLs)
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
        match: (NSPasteboardItem, NSPasteboard.PasteboardType)?,
        fileURLs: [URL],
        pasteboard: any PasteboardAccess,
        sourceChangeCount: Int,
        payloadReader: any PasteboardPayloadReading
    ) async -> ClipboardWebPCapture {
        let result: ClipboardWebPCapture
        if let (item, type) = match {
            switch await payloadReader.readData(
                from: item,
                forType: type,
                maximumBytes: ClipboardWebPConfiguration.maximumSourceBytes
            ) {
            case let .data(data):
                result = fileURLs.isEmpty
                    ? .source(.data(data), changeCount: sourceChangeCount)
                    : .source(.files(fileURLs, fallback: data), changeCount: sourceChangeCount)
            case .missing, .tooLarge:
                result = fileURLs.isEmpty
                    ? .failed
                    : .source(.files(fileURLs, fallback: nil), changeCount: sourceChangeCount)
            case .cancelled:
                return .stale
            case .timedOut, .failed, .unavailable:
                result = .unavailable
            }
        } else {
            result = fileURLs.isEmpty
                ? .noImage
                : .source(.files(fileURLs, fallback: nil), changeCount: sourceChangeCount)
        }

        guard !Task.isCancelled, pasteboard.changeCount == sourceChangeCount else {
            return .stale
        }
        return result
    }
}
