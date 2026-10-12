import AppKit

nonisolated enum PasteboardSnapshotPolicy {
    static let maximumBytes = 150 * 1_024 * 1_024
    static let maximumItems = 128
    static let maximumTypesPerItem = 64
}

@MainActor
struct PasteboardSnapshot {
    static let defaultMaximumItems = PasteboardSnapshotPolicy.maximumItems
    nonisolated static let maximumFileURLBytes = 1 * 1_024 * 1_024
    nonisolated static let maximumFileURLReadDuration: TimeInterval = 0.25
    struct Limits {
        let maximumBytes: Int
        let maximumItems: Int
        let maximumTypesPerItem: Int
    }
    struct ContentMatchConfiguration {
        let maximumBytes: Int
        let maximumTypesPerItem: Int
        let fileURLReader: any PasteboardFileURLReading
        let payloadReader: any PasteboardPayloadReading
    }

    struct FileURLConfiguration {
        let maximumItems: Int
        let maximumTypesPerItem: Int
        let maximumReadDuration: TimeInterval
        let fileURLReader: any PasteboardFileURLReading
    }

    enum CaptureResult {
        case captured(PasteboardSnapshot)
        case stale
        case failed
    }

    enum ReplacementResult {
        case installed(changeCount: Int)
        case stale
        case failed(restoredChangeCount: Int)
        case restoreFailed
    }

    /// A representation already read during source selection and reused for rollback capture.
    struct MaterializedRepresentation {
        let itemIndex: Int
        let type: NSPasteboard.PasteboardType
        /// `nil` records that the earlier read did not produce readable data.
        let data: Data?
    }
    let items: [NSPasteboardItem]
}
