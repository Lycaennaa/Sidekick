import CoreGraphics
import Foundation
import ImageIO

nonisolated enum ClipboardAVIFEncoder {
    typealias CancellationCheck = ClipboardImageConversionPolicy.CancellationCheck

    static func encode(
        _ image: CGImage,
        isCancelled: CancellationCheck
    ) throws -> Data {
        try checkCancellation(isCancelled)
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded as CFMutableData,
            ClipboardImageFormat.avif.typeIdentifier as CFString,
            1,
            nil
        ) else {
            throw ClipboardImageConversionError.cannotEncode
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: ClipboardImageConversionPolicy.quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ClipboardImageConversionError.cannotEncode
        }
        try checkCancellation(isCancelled)
        guard encoded.length > 0 else {
            throw ClipboardImageConversionError.cannotEncode
        }
        guard encoded.length <= ClipboardImageConversionPolicy.maximumOutputBytes else {
            throw ClipboardImageConversionError.tooLarge
        }
        return encoded as Data
    }

    private static func checkCancellation(_ isCancelled: CancellationCheck) throws {
        guard !isCancelled(), !Task.isCancelled else { throw CancellationError() }
    }
}
