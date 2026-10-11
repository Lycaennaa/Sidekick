import Foundation

nonisolated enum ClipboardWebPConfiguration {
    static let quality = 0.75
    static let maximumSourceBytes = 100 * 1_024 * 1_024
    static let maximumOutputBytes = maximumSourceBytes
    static let maximumAggregateSourceBytes = PasteboardSnapshotPolicy.maximumBytes
    static let maximumPixelCount = 50_000_000
    static let defaultOutputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Sidekick-ClipboardWebP", isDirectory: true)
}

enum ClipboardWebPCapture {
    case source(ClipboardWebPSource, changeCount: Int)
    case alreadyWebP
    case noImage
    case unavailable
    case failed
    case stale
}

enum ClipboardWebPSource: Sendable {
    case data(Data)
    case files([URL], fallback: Data?)
}

enum ClipboardWebPConversionError: Error, Sendable, Equatable {
    case tooLarge
    case invalidImage
    case cannotEncode
    case cannotWrite
    case cannotCreateFilename
}

enum ClipboardWebPConversionFailure: Error, Sendable, Equatable {
    case conversion(ClipboardWebPConversionError)
    case unexpected(String)
}
