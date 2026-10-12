import Foundation

@MainActor
struct ClipboardImageConversionCapturedSource {
    let source: ClipboardImageSource
    let changeCount: Int
    let snapshot: PasteboardSnapshot
}

@MainActor
enum ClipboardImageConversionCapture {
    case source(ClipboardImageConversionCapturedSource)
    case alreadyOutputFormat
    case noImage
    case unavailable
    case failed
    case stale
}

enum ClipboardImageSource: Sendable {
    case data(Data)
    case files([URL], fallback: Data?)
}
