import Foundation

nonisolated enum ClipboardImageConversionPolicy {
    typealias CancellationCheck = @Sendable () -> Bool

    static let qualityPresets = [0.25, 0.5, 0.75, 0.9, 1.0]
    static func isValidQuality(_ quality: Double) -> Bool {
        quality.isFinite && (0...1).contains(quality)
    }
    static let quality = 0.75
    static let screenshotQuality = 0.90
    static let maximumSourceBytes = 100 * 1_024 * 1_024
    static let maximumOutputBytes = maximumSourceBytes
    static let maximumAggregateSourceBytes = PasteboardSnapshotPolicy.maximumBytes
    static let maximumPixelCount = 50_000_000
    static let defaultOutputDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Sidekick-ClipboardImages", isDirectory: true)
    static let legacyOutputDirectories = [
        FileManager.default.temporaryDirectory.appendingPathComponent("Sidekick-ClipboardWebP", isDirectory: true)
    ]
}

enum ClipboardImageConversionError: Error, Sendable, Equatable {
    case tooLarge
    case invalidImage
    case cannotEncode
    case cannotWrite
    case cannotCreateFilename
}

enum ClipboardImageConversionFailure: Error, Sendable, Equatable {
    case conversion(ClipboardImageConversionError)
    case unexpected(String)
}
