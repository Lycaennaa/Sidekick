import CoreGraphics
import Foundation
import libwebp

nonisolated enum ClipboardWebPEncoder {
    typealias CancellationCheck = ClipboardImageConversionPolicy.CancellationCheck

    private static let pixelCancellationInterval = 16 * 1_024

    static func encode(
        _ image: CGImage,
        isCancelled: CancellationCheck
    ) throws -> Data {
        try checkCancellation(isCancelled)
        let rendered = try renderPixels(from: image)
        try checkCancellation(isCancelled)
        var pixels = rendered.data
        try unpremultiply(&pixels, isCancelled: isCancelled)
        return try encodeRGBA(
            pixels: pixels,
            width: rendered.width,
            height: rendered.height,
            bytesPerRow: rendered.bytesPerRow,
            isCancelled: isCancelled
        )
    }

    private static func checkCancellation(_ isCancelled: CancellationCheck) throws {
        guard !isCancelled(), !Task.isCancelled else { throw CancellationError() }
    }
}
nonisolated private extension ClipboardWebPEncoder {
    private struct RenderedPixels {
        let data: Data
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    private static func renderPixels(from image: CGImage) throws -> RenderedPixels {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: baseAddress,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                          | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw ClipboardImageConversionError.invalidImage }
        return RenderedPixels(
            data: pixels,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }

    static func unpremultiply(
        _ pixels: inout Data,
        isCancelled: CancellationCheck
    ) throws {
        var cancelledDuringUnpremultiply = false
        pixels.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            let channels = bytes.bindMemory(to: UInt8.self)
            var pixelIndex = 0
            for pixelOffset in stride(from: 0, to: channels.count, by: 4) {
                if pixelIndex % pixelCancellationInterval == 0,
                   isCancelled() {
                    cancelledDuringUnpremultiply = true
                    return
                }
                let alpha = Int(channels[pixelOffset + 3])
                if alpha > 0, alpha < 255 {
                    for channelOffset in 0..<3 {
                        let value = Int(channels[pixelOffset + channelOffset])
                        channels[pixelOffset + channelOffset] = UInt8(min(255, value * 255 / alpha))
                    }
                }
                pixelIndex += 1
            }
        }
        try checkCancellation(isCancelled)
        if cancelledDuringUnpremultiply {
            throw CancellationError()
        }
    }

    static func encodeRGBA(
        pixels: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        isCancelled: CancellationCheck
    ) throws -> Data {
        try checkCancellation(isCancelled)
        var encodedBytes: UnsafeMutablePointer<UInt8>?
        let byteCount = pixels.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            WebPEncodeRGBA(
                bytes.bindMemory(to: UInt8.self).baseAddress,
                Int32(width),
                Int32(height),
                Int32(bytesPerRow),
                Float(ClipboardImageConversionPolicy.quality * 100),
                &encodedBytes
            )
        }
        guard byteCount > 0, let encodedBytes else {
            throw ClipboardImageConversionError.cannotEncode
        }
        defer { WebPFree(encodedBytes) }
        try checkCancellation(isCancelled)
        let data = Data(bytes: encodedBytes, count: byteCount)
        try checkCancellation(isCancelled)
        return data
    }
}
