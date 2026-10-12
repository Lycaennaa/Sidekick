import UniformTypeIdentifiers

nonisolated enum ClipboardImageFormat: String, CaseIterable, Sendable {
    case webP = "webp"
    case avif

    var displayName: String {
        switch self {
        case .webP: "WebP"
        case .avif: "AVIF"
        }
    }

    var fileExtension: String {
        switch self {
        case .webP: "webp"
        case .avif: "avif"
        }
    }

    var typeIdentifier: String {
        switch self {
        case .webP: UTType.webP.identifier
        case .avif: "public.avif"
        }
    }

    var uniformType: UTType {
        switch self {
        case .webP: .webP
        case .avif: UTType(importedAs: typeIdentifier, conformingTo: .image)
        }
    }

    init?(fileExtension: String) {
        self.init(rawValue: fileExtension.lowercased())
    }
}
