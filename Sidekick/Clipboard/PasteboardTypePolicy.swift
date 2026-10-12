import AppKit
import UniformTypeIdentifiers

@MainActor
enum PasteboardTypePolicy {
    static func containsFileURL(
        in item: NSPasteboardItem,
        maximumTypesPerItem: Int
    ) -> Bool {
        guard maximumTypesPerItem >= 0 else { return false }
        return item.types.prefix(maximumTypesPerItem).contains(.fileURL)
    }

    static func isImage(_ type: NSPasteboard.PasteboardType) -> Bool {
        return ClipboardImageFormat.allCases.contains { $0.typeIdentifier == type.rawValue }
            || UTType(type.rawValue)?.conforms(to: .image) == true
    }
    static func isImage(_ type: UTType) -> Bool {
        type.conforms(to: .image)
    }

    static func imageType(for url: URL) -> UTType? {
        if let format = ClipboardImageFormat(fileExtension: url.pathExtension) {
            return format.uniformType
        }
        guard let type = UTType(filenameExtension: url.pathExtension),
              isImage(type) else {
            return nil
        }
        return type
    }

    static func isImage(url: URL) -> Bool {
        imageType(for: url) != nil
    }

    static func url(from data: Data, localOnly: Bool = false) -> URL? {
        guard let value = PasteboardPayloadReader.string(from: data),
              let url = URL(string: value),
              !localOnly || isLocalFileURL(url) else {
            return nil
        }
        return url
    }
}
