import AppKit

@MainActor
extension PasteboardSnapshot {
    static func boundedItems(
        from pasteboard: any PasteboardAccess,
        maximumItems: Int,
        rejectingOverflow: Bool = false
    ) -> [NSPasteboardItem]? {
        guard maximumItems >= 0 else { return nil }
        // AppKit exposes no count/indexed-item API; this is the sole item-array boundary.
        guard let sourceItems = pasteboard.pasteboardItems else { return [] }
        guard sourceItems.count <= maximumItems else {
            return rejectingOverflow ? nil : Array(sourceItems.prefix(maximumItems))
        }
        return sourceItems
    }

    static func boundedFileURLs(
        from pasteboard: any PasteboardAccess,
        maximumItems: Int,
        maximumTypesPerItem: Int,
        expectedChangeCount: Int? = nil,
        maximumReadDuration: TimeInterval = maximumFileURLReadDuration,
        fileURLReader: any PasteboardFileURLReading = SystemPasteboardFileURLReader()
    ) async -> [URL]? {
        guard maximumTypesPerItem >= 0,
              maximumReadDuration.isFinite,
              maximumReadDuration >= 0 else {
            return nil
        }
        guard expectedChangeCount == nil || pasteboard.changeCount == expectedChangeCount else {
            return nil
        }
        guard let items = boundedItems(
            from: pasteboard,
            maximumItems: maximumItems,
            rejectingOverflow: true
        ) else {
            return nil
        }
        let request = FileURLScanRequest(
            pasteboard: pasteboard,
            expectedChangeCount: expectedChangeCount,
            maximumTypesPerItem: maximumTypesPerItem,
            maximumReadDuration: maximumReadDuration,
            fileURLReader: fileURLReader
        )
        return await collectFileURLs(in: items, request: request)
    }

    private static func fileURL(
        from item: NSPasteboardItem,
        maximumReadDuration: TimeInterval,
        fileURLReader: any PasteboardFileURLReading
    ) async -> URL? {
        guard case let .data(data) = await fileURLReader.readFileURLData(
            from: item,
            maximumBytes: maximumFileURLBytes,
            timeout: maximumReadDuration
        ),
        !Task.isCancelled,
        let url = PasteboardTypePolicy.url(from: data) else {
            return nil
        }
        return url.standardizedFileURL
    }

    static func exactFileURL(
        from pasteboard: any PasteboardAccess,
        maximumItems: Int,
        maximumTypesPerItem: Int,
        expectedChangeCount: Int? = nil,
        maximumReadDuration: TimeInterval = maximumFileURLReadDuration,
        fileURLReader: any PasteboardFileURLReading = SystemPasteboardFileURLReader()
    ) async -> URL? {
        guard maximumReadDuration.isFinite, maximumReadDuration >= 0 else {
            return nil
        }
        if let expectedChangeCount,
           pasteboard.changeCount != expectedChangeCount {
            return nil
        }
        guard let items = boundedItems(
            from: pasteboard,
            maximumItems: maximumItems,
            rejectingOverflow: true
        ),
        items.count == 1,
        let item = items.first else {
            return nil
        }
        let types = item.types
        guard maximumTypesPerItem >= 1,
              types.count <= maximumTypesPerItem,
              types.count == 1,
              types.first == .fileURL,
              let url = await fileURL(
                  from: item,
                  maximumReadDuration: maximumReadDuration,
                  fileURLReader: fileURLReader
              ),
              !Task.isCancelled else {
            return nil
        }
        if let expectedChangeCount,
           pasteboard.changeCount != expectedChangeCount {
            return nil
        }
        return url
    }

    static func capture(
        from pasteboard: any PasteboardAccess,
        expectedChangeCount: Int,
        limits: Limits,
        sourceItems: [NSPasteboardItem]? = nil,
        materializedRepresentations: [MaterializedRepresentation] = [],
        fileURLReader: any PasteboardFileURLReading = SystemPasteboardFileURLReader(),
        payloadReader: any PasteboardPayloadReading = SystemPasteboardPayloadReader()
    ) async -> CaptureResult {
        guard !Task.isCancelled,
              pasteboard.changeCount == expectedChangeCount else { return .stale }
        let capturedItems: [NSPasteboardItem]
        if let sourceItems {
            guard sourceItems.count <= limits.maximumItems else { return .failed }
            capturedItems = sourceItems
        } else {
            guard let boundedItems = boundedItems(
                from: pasteboard,
                maximumItems: limits.maximumItems,
                rejectingOverflow: true
            ) else {
                return .failed
            }
            capturedItems = boundedItems
        }
        var cachedRepresentations: [MaterializedRepresentationKey: MaterializedRepresentationValue] = [:]
        for representation in materializedRepresentations {
            let key = MaterializedRepresentationKey(
                itemIndex: representation.itemIndex,
                typeIdentifier: representation.type.rawValue
            )
            if let data = representation.data {
                cachedRepresentations[key] = .data(data)
            } else {
                cachedRepresentations[key] = .failed
            }
        }
        let request = CaptureRequest(
            pasteboard: pasteboard,
            expectedChangeCount: expectedChangeCount,
            limits: limits,
            cachedRepresentations: cachedRepresentations,
            fileURLReader: fileURLReader,
            payloadReader: payloadReader
        )
        return await captureItems(capturedItems, request: request)
    }

    static func contentsMatch(
        currentItems: [NSPasteboardItem]?,
        expectedItems: [NSPasteboardItem],
        configuration: ContentMatchConfiguration
    ) async -> Bool {
        guard configuration.maximumBytes >= 0,
              configuration.maximumTypesPerItem >= 0 else {
            return false
        }
        guard let currentItems else { return expectedItems.isEmpty }
        guard currentItems.count == expectedItems.count else { return false }

        var remainingBytes = configuration.maximumBytes
        for (currentItem, expectedItem) in zip(currentItems, expectedItems) {
            let expectedTypes = expectedItem.types
            guard expectedTypes.count <= configuration.maximumTypesPerItem,
                  currentItem.types == expectedTypes else {
                return false
            }
            for type in expectedTypes {
                guard let expectedData = await boundedData(
                    from: expectedItem,
                    forType: type,
                    maximumBytes: remainingBytes,
                    configuration: configuration
                ),
                let currentData = await boundedData(
                    from: currentItem,
                    forType: type,
                    maximumBytes: remainingBytes,
                    configuration: configuration
                ),
                expectedData.count <= remainingBytes,
                currentData.count <= remainingBytes,
                expectedData == currentData else {
                    return false
                }
                remainingBytes -= currentData.count
            }
        }
        return true
    }

    private static func boundedData(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int,
        configuration: ContentMatchConfiguration
    ) async -> Data? {
        guard maximumBytes >= 0, !Task.isCancelled else { return nil }
        if type == .fileURL {
            guard case let .data(data) = await configuration.fileURLReader.readFileURLData(
                from: item,
                maximumBytes: maximumBytes,
                timeout: maximumFileURLReadDuration
            ) else {
                return nil
            }
            return data
        }
        guard case let .data(data) = await configuration.payloadReader.readData(
            from: item,
            forType: type,
            maximumBytes: maximumBytes
        ) else {
            return nil
        }
        return data
    }

}
@MainActor
private extension PasteboardSnapshot {
    private struct FileURLScanRequest {
        let pasteboard: any PasteboardAccess
        let expectedChangeCount: Int?
        let maximumTypesPerItem: Int
        let maximumReadDuration: TimeInterval
        let fileURLReader: any PasteboardFileURLReading
    }

    private static func collectFileURLs(
        in items: [NSPasteboardItem],
        request: FileURLScanRequest
    ) async -> [URL]? {
        var urls: [URL] = []
        for item in items {
            guard isCurrent(request) else { return nil }
            guard item.types.count <= request.maximumTypesPerItem else { return nil }
            guard PasteboardTypePolicy.containsFileURL(
                in: item,
                maximumTypesPerItem: request.maximumTypesPerItem
            ) else {
                continue
            }
            guard let url = await fileURL(
                from: item,
                maximumReadDuration: request.maximumReadDuration,
                fileURLReader: request.fileURLReader
            ), isCurrent(request) else {
                return nil
            }
            urls.append(url)
        }
        guard isCurrent(request) else { return nil }
        return urls
    }

    private static func isCurrent(_ request: FileURLScanRequest) -> Bool {
        !Task.isCancelled
            && (request.expectedChangeCount == nil
                || request.pasteboard.changeCount == request.expectedChangeCount)
    }

    private struct MaterializedRepresentationKey: Hashable {
        let itemIndex: Int
        let typeIdentifier: String
    }

    private enum MaterializedRepresentationValue {
        case data(Data)
        case failed
    }

    private struct CaptureRequest {
        let pasteboard: any PasteboardAccess
        let expectedChangeCount: Int
        let limits: Limits
        let cachedRepresentations: [MaterializedRepresentationKey: MaterializedRepresentationValue]
        let fileURLReader: any PasteboardFileURLReading
        let payloadReader: any PasteboardPayloadReading
    }

    private enum CaptureDataResult {
        case data(Data)
        case stale
        case failed
    }

    private enum CaptureItemResult {
        case copied(NSPasteboardItem)
        case stale
        case failed
    }

    private static func captureItems(
        _ sourceItems: [NSPasteboardItem],
        request: CaptureRequest
    ) async -> CaptureResult {
        var totalBytes = 0
        var copies: [NSPasteboardItem] = []
        copies.reserveCapacity(sourceItems.count)
        for (itemIndex, sourceItem) in sourceItems.enumerated() {
            guard isCurrent(request) else { return .stale }
            guard sourceItem.types.count <= request.limits.maximumTypesPerItem else {
                return .failed
            }
            switch await copyItem(
                sourceItem,
                itemIndex: itemIndex,
                totalBytes: &totalBytes,
                request: request
            ) {
            case let .copied(copy):
                guard isCurrent(request) else { return .stale }
                copies.append(copy)
            case .stale:
                return .stale
            case .failed:
                return .failed
            }
        }
        guard isCurrent(request) else { return .stale }
        return .captured(PasteboardSnapshot(items: copies))
    }

    private static func copyItem(
        _ sourceItem: NSPasteboardItem,
        itemIndex: Int,
        totalBytes: inout Int,
        request: CaptureRequest
    ) async -> CaptureItemResult {
        let copy = NSPasteboardItem()
        for type in sourceItem.types {
            guard isCurrent(request) else { return .stale }
            switch await captureData(
                from: sourceItem,
                itemIndex: itemIndex,
                forType: type,
                maximumBytes: request.limits.maximumBytes - totalBytes,
                request: request
            ) {
            case let .data(data):
                guard isCurrent(request) else { return .stale }
                guard data.count <= request.limits.maximumBytes - totalBytes,
                      copy.setData(data, forType: type) else {
                    return .failed
                }
                totalBytes += data.count
            case .stale:
                return .stale
            case .failed:
                return .failed
            }
        }
        return .copied(copy)
    }

    private static func captureData(
        from item: NSPasteboardItem,
        itemIndex: Int,
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int,
        request: CaptureRequest
    ) async -> CaptureDataResult {
        let key = MaterializedRepresentationKey(
            itemIndex: itemIndex,
            typeIdentifier: type.rawValue
        )
        if let cached = request.cachedRepresentations[key] {
            switch cached {
            case let .data(data):
                return .data(data)
            case .failed:
                return .failed
            }
        }
        if type == .fileURL {
            let result = await request.fileURLReader.readFileURLData(
                from: item,
                maximumBytes: maximumBytes,
                timeout: maximumFileURLReadDuration
            )
            guard isCurrent(request) else { return .stale }
            switch result {
            case let .data(value):
                return .data(value)
            case .cancelled:
                return .stale
            case .missing, .tooLarge, .timedOut, .unavailable, .failed:
                return .failed
            }
        }

        let result = await request.payloadReader.readData(
            from: item,
            forType: type,
            maximumBytes: maximumBytes
        )
        guard isCurrent(request) else { return .stale }
        guard case let .data(value) = result else { return .failed }
        return .data(value)
    }

    private static func isCurrent(_ request: CaptureRequest) -> Bool {
        !Task.isCancelled && request.pasteboard.changeCount == request.expectedChangeCount
    }
}
