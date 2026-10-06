import CoreGraphics
import Foundation

func attributedSourceApplication<Value: Equatable>(
    previous: Value?,
    current: Value?,
    applicationChanged: Bool
) -> Value? {
    !applicationChanged && previous == current ? current : nil
}

nonisolated func byteCountLabel(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
}

nonisolated func isLocalFileURL(_ url: URL) -> Bool {
    guard url.isFileURL else { return false }
    guard let host = url.host else { return true }
    return host.isEmpty || host.caseInsensitiveCompare("localhost") == .orderedSame
}
enum ClipboardImageEnrichmentKind: Equatable, Sendable {
    case data
    case localFile
}

struct ClipboardImageEnrichmentRequest: Equatable, Sendable {
    let generation: UInt64
    let kind: ClipboardImageEnrichmentKind
    let source: Source

    enum Source: Equatable, Sendable {
        case data(Data, typeIdentifier: String)
        case localFile(URL, typeIdentifier: String)
    }

    init(generation: UInt64, data: Data, typeIdentifier: String) {
        self.generation = generation
        kind = .data
        source = .data(data, typeIdentifier: typeIdentifier)
    }

    init(generation: UInt64, localFileURL: URL, typeIdentifier: String) {
        self.generation = generation
        kind = .localFile
        source = .localFile(localFileURL, typeIdentifier: typeIdentifier)
    }

    nonisolated var typeIdentifier: String {
        switch source {
        case let .data(_, typeIdentifier), let .localFile(_, typeIdentifier):
            typeIdentifier
        }
    }
}

struct ClipboardImageEnrichment: @unchecked Sendable {
    let generation: UInt64
    let kind: ClipboardImageEnrichmentKind
    let thumbnail: CGImage
    let imageFooter: String?
}

enum ClipboardScreenshotDynamicRange: String, Equatable, Sendable {
    case sdr
    case hdr

    var toastLabel: String {
        switch self {
        case .sdr: "SDR (HDR not preserved)"
        case .hdr: "HDR"
        }
    }
}

enum ClipboardPayloadClassification: Equatable, Sendable {
    case files(
        generation: UInt64,
        firstName: String,
        count: Int,
        overflow: Bool,
        uncertain: Bool,
        representativeFileURL: URL?,
        imageEnrichment: ClipboardImageEnrichmentRequest?
    )
    case image(
        generation: UInt64,
        byteCount: Int?,
        imageEnrichment: ClipboardImageEnrichmentRequest?,
        screenshotDynamicRange: ClipboardScreenshotDynamicRange?
    )
    case text(
        generation: UInt64,
        preview: String?,
        oversizedByteCount: Int?
    )
    case generic(generation: UInt64, typeDescription: String?)
    case unavailable(generation: UInt64)

    var generation: UInt64 {
        switch self {
        case let .files(generation, _, _, _, _, _, _):
            return generation
        case let .image(generation, _, _, _):
            return generation
        case let .text(generation, _, _):
            return generation
        case let .generic(generation, _):
            return generation
        case let .unavailable(generation):
            return generation
        }
    }
}

nonisolated struct ClipboardTextMetrics: Equatable, Sendable {
    let wordCount: Int
    let characterCount: Int
    let tokenCount: Int
    var formattedDescription: String {
        "\(wordCount) \(wordCount == 1 ? "word" : "words") • "
            + "\(characterCount) \(characterCount == 1 ? "character" : "characters") • "
            + "\(tokenCount) \(tokenCount == 1 ? "token" : "tokens")"
    }

    static func count(in text: String, using tokenizer: ClipboardTokenizer) async -> Self? {
        do {
            let tokenCount = try await tokenizer.countTokens(in: text)
            return Self(
                wordCount: text.split(whereSeparator: \.isWhitespace).count,
                characterCount: text.count,
                tokenCount: tokenCount
            )
        } catch {
            return nil
        }
    }
}

struct ClipboardTextFingerprint: Equatable, Sendable {
    let typeIdentifier: String
    let itemTypeIdentifiers: [String]
    let byteCount: Int
    let digest: Data
}

struct ClipboardPayloadAnalysis: Equatable, Sendable {
    let classification: ClipboardPayloadClassification
    let textFingerprint: ClipboardTextFingerprint?
    let textMetrics: ClipboardTextMetrics?
}
