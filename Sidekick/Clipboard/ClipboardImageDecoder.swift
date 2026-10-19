import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ClipboardImageDecoder {
    static let maximumSourceBytes = 100 * 1_024 * 1_024
    static let maximumThumbnailPixelSize = 384

    static func decode(
        _ request: ClipboardImageEnrichmentRequest,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> ClipboardImageEnrichment? {
        guard !isCancelled(),
              let data = sourceData(for: request, isCancelled: isCancelled),
              !isCancelled(),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              !isCancelled()
        else {
            return nil
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        guard !isCancelled() else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumThumbnailPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ), !isCancelled() else {
            return nil
        }

        var details: [String] = []
        if let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 {
            details.append("\(pixelWidth) × \(pixelHeight)")
        }
        let sourceType = (CGImageSourceGetType(source) as String?) ?? request.typeIdentifier
        let encodedFormatCandidate = UTType(sourceType)?.preferredFilenameExtension?.uppercased()
        let encodedFormat = encodedFormatCandidate.flatMap { $0.count <= 12 ? $0 : nil }
        let declaredFormatCandidate = UTType(request.typeIdentifier)
            .flatMap { $0.conforms(to: .image) ? $0.preferredFilenameExtension?.uppercased() : nil }
        let declaredFormat = declaredFormatCandidate.flatMap { $0.count <= 12 ? $0 : nil }
        // Keep the advertised clipboard type visible alongside the bytes' detected encoding.
        let format: String?
        if let declaredFormat, let encodedFormat, declaredFormat != encodedFormat {
            format = "\(declaredFormat) type, \(encodedFormat) data"
        } else {
            format = declaredFormat ?? encodedFormat
        }
        if let format,
           !format.isEmpty,
           format.count <= 40 {
            details.append(format)
        }
        var imageFooter = details
        imageFooter.append(byteCountLabel(data.count))

        return ClipboardImageEnrichment(
            generation: request.generation,
            kind: request.kind,
            thumbnail: thumbnail,
            imageFooter: imageFooter.joined(separator: " • ")
        )
    }

    private static func sourceData(
        for request: ClipboardImageEnrichmentRequest,
        isCancelled: @Sendable () -> Bool
    ) -> Data? {
        switch request.source {
        case let .data(data, _):
            return data.count <= maximumSourceBytes ? data : nil
        case let .localFile(url, typeIdentifier):
            guard isLocalFileURL(url),
                  UTType(typeIdentifier)?.conforms(to: .image) == true,
                  !isCancelled()
            else {
                return nil
            }

            let descriptor = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            }
            guard descriptor >= 0 else { return nil }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }

            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_size >= 0,
                  status.st_size <= maximumSourceBytes,
                  !isCancelled()
            else {
                return nil
            }

            var data = Data()
            data.reserveCapacity(Int(status.st_size))
            while data.count <= maximumSourceBytes {
                guard !isCancelled() else { return nil }
                let remaining = maximumSourceBytes + 1 - data.count
                guard let chunk = try? handle.read(upToCount: min(1_024 * 1_024, remaining)),
                      !chunk.isEmpty
                else {
                    break
                }
                data.append(chunk)
            }
            return data.count <= maximumSourceBytes ? data : nil
        }
    }
}
