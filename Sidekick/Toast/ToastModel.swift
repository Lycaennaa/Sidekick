import AppKit

enum ToastPresentationStyle: Equatable, Sendable {
    case files
    case image
    case text
    case generic
}

struct ToastModel {
    let generation: UInt64
    let presentationStyle: ToastPresentationStyle
    let summary: String
    let detail: String?
    let icon: NSImage?
    var showsImagePreview = false
    var onUserAction: (@MainActor () -> Void)?
    var footer: String?

    static func generic(generation: UInt64) -> Self {
        Self(
            generation: generation,
            presentationStyle: .generic,
            summary: "Copied item",
            detail: nil,
            icon: NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Copied item")
        )
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
