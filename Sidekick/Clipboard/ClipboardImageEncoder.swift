import Foundation
import ImageIO

nonisolated enum ClipboardImageEncoder {
    typealias CancellationCheck = ClipboardImageConversionPolicy.CancellationCheck

    static func encode(
        _ data: Data,
        format: ClipboardImageFormat,
        isCancelled: CancellationCheck
    ) throws -> Data {
        let image = try makeThumbnail(from: data, isCancelled: isCancelled)
        switch format {
        case .webP:
            return try ClipboardWebPEncoder.encode(image, isCancelled: isCancelled)
        case .avif:
            return try ClipboardAVIFEncoder.encode(image, isCancelled: isCancelled)
        }
    }

    static func encodeInBackground(
        _ data: Data,
        format: ClipboardImageFormat
    ) async throws -> Data {
        let worker = Task.detached(priority: .userInitiated) {
            try encode(data, format: format, isCancelled: { Task.isCancelled })
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func makeThumbnail(
        from data: Data,
        isCancelled: CancellationCheck
    ) throws -> CGImage {
        try checkCancellation(isCancelled)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ClipboardImageConversionError.invalidImage
        }
        try checkCancellation(isCancelled)
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= ClipboardImageConversionPolicy.maximumPixelCount / height else {
            throw ClipboardImageConversionError.invalidImage
        }
        try checkCancellation(isCancelled)
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary
        ) else {
            throw ClipboardImageConversionError.invalidImage
        }
        try checkCancellation(isCancelled)
        return image
    }

    private static func checkCancellation(_ isCancelled: CancellationCheck) throws {
        guard !isCancelled(), !Task.isCancelled else { throw CancellationError() }
    }
}
