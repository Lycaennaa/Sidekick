import AppKit

@MainActor
protocol PasteboardAccess: AnyObject {
    var changeCount: Int { get }
    var pasteboardItems: [NSPasteboardItem]? { get }

    @discardableResult
    func clearContents() -> Int
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: PasteboardAccess {}

@MainActor
protocol PasteboardPayloadReading {
    /// `maximumBytes` limits bytes accepted from the materialized result;
    /// it is not an allocation cap.
    /// Native provider work is bounded by the adapter's result deadline,
    /// not preempted by it.
    func readData(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int
    ) async -> PasteboardPayloadReader.Result
}

@MainActor
struct SystemPasteboardPayloadReader: PasteboardPayloadReading {
    func readData(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int
    ) async -> PasteboardPayloadReader.Result {
        await PasteboardPayloadReader.readData(
            from: item,
            forType: type,
            maximumBytes: maximumBytes
        )
    }
}

enum PasteboardPayloadReader {
    static let maximumFileURLBytes = SystemPasteboardFileURLReader.maximumAcceptedBytes
    static let maximumFileURLReadDuration = SystemPasteboardFileURLReader.resultDeadlineInterval

    typealias Result = PasteboardBoundedReadResult

    /// Native provider data is materialized before `maximumBytes` is checked.
    /// The fixed deadline bounds result delivery; it does not preempt AppKit.
    @MainActor
    static func readData(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int
    ) async -> Result {
        guard maximumBytes >= 0 else { return .missing }
        guard !Task.isCancelled else { return .cancelled }
        let result = await PasteboardNativeMaterializationGateway.readData(
            from: item,
            forType: type,
            maximumAcceptedBytes: maximumBytes,
            deadlineInterval: maximumFileURLReadDuration
        )
        return Task.isCancelled ? .cancelled : result
    }

    @MainActor
    static func readData(
        from items: [NSPasteboardItem],
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int,
        payloadReader: any PasteboardPayloadReading = SystemPasteboardPayloadReader()
    ) async -> Result {
        guard maximumBytes >= 0 else { return .missing }
        guard !Task.isCancelled else { return .cancelled }
        var data = Data()
        var hasData = false
        for item in items {
            guard !Task.isCancelled else { return .cancelled }
            let result = await payloadReader.readData(
                from: item,
                forType: type,
                maximumBytes: maximumBytes
            )
            switch result {
            case .missing:
                continue
            case .unavailable, .timedOut, .cancelled, .failed:
                return result
            case .tooLarge:
                return result
            case let .data(value):
                let separatorBytes = hasData ? 1 : 0
                guard value.count <= maximumBytes - data.count - separatorBytes else {
                    return .tooLarge(byteCount: data.count + separatorBytes + value.count)
                }
                if hasData {
                    data.append(0x0A)
                }
                data.append(value)
                hasData = true
            }
        }
        return hasData ? .data(data) : .missing
    }

    @MainActor
    static func readData(
        from pasteboard: NSPasteboard,
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int,
        payloadReader: any PasteboardPayloadReading = SystemPasteboardPayloadReader()
    ) async -> Result {
        guard maximumBytes >= 0 else { return .missing }
        guard !Task.isCancelled else { return .cancelled }
        let result = await readData(
            from: pasteboard.pasteboardItems ?? [],
            forType: type,
            maximumBytes: maximumBytes,
            payloadReader: payloadReader
        )
        return Task.isCancelled ? .cancelled : result
    }

    @MainActor
    static func readString(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int = 1 * 1_024 * 1_024
    ) async -> String? {
        if type == .fileURL {
            guard case let .data(data) = await readFileURLData(
                from: item,
                maximumBytes: maximumBytes
            ), !Task.isCancelled else {
                return nil
            }
            return string(from: data)
        }
        guard case let .data(data) = await readData(
            from: item,
            forType: type,
            maximumBytes: maximumBytes
        ) else {
            return nil
        }
        return string(from: data)
    }

    static func string(from data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
    }

    @MainActor
    static func readFileURLData(
        from item: NSPasteboardItem,
        maximumBytes: Int = maximumFileURLBytes
    ) async -> PasteboardFileURLReadResult {
        await SystemPasteboardFileURLReader().readFileURLData(
            from: item,
            maximumBytes: maximumBytes,
            timeout: maximumFileURLReadDuration
        )
    }
}
