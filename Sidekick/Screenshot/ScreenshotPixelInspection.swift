import AppKit
import CoreGraphics

struct ScreenshotPixelCoordinate: Equatable {
    let column: Int
    let row: Int
}

struct ScreenshotPixelRGB: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

struct ScreenshotPixelSample: Equatable {
    let coordinate: ScreenshotPixelCoordinate
    let srgb: ScreenshotPixelRGB
    let displayP3Value: String
    let relativeEDRValue: String?

    var srgbValue: String {
        "\(srgb.red), \(srgb.green), \(srgb.blue)"
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int(srgb.red), Int(srgb.green), Int(srgb.blue))
    }
}

@MainActor
final class ScreenshotPixelInspector {
    private static let extendedColorSpaceNames: Set<String> = [
        CGColorSpace.extendedSRGB as String,
        CGColorSpace.extendedLinearSRGB as String,
        CGColorSpace.extendedDisplayP3 as String,
        CGColorSpace.extendedLinearDisplayP3 as String,
        CGColorSpace.extendedLinearITUR_2020 as String
    ]

    let imageSize: CGSize
    private let bytesPerRow: Int
    private let bytesPerPixel: Int
    private let usesFloatComponents: Bool
    private let exposesRelativeEDR: Bool
    private let pixelColorSpace: CGColorSpace?
    private let pixelData: Data?

    init(image: CGImage) {
        imageSize = CGSize(width: image.width, height: image.height)
        let colorSpaceName = image.colorSpace?.name as String?
        let usesFloatComponents = Self.extendedColorSpaceNames.contains(colorSpaceName ?? "")
        let bytesPerPixel = usesFloatComponents ? 8 : 4
        self.bytesPerPixel = bytesPerPixel
        self.usesFloatComponents = usesFloatComponents
        exposesRelativeEDR = usesFloatComponents
        let (rowBytes, rowOverflow) = image.width.multipliedReportingOverflow(by: bytesPerPixel)
        let (byteCount, countOverflow) = rowBytes.multipliedReportingOverflow(by: image.height)
        guard image.width > 0, image.height > 0, !rowOverflow, !countOverflow,
              let colorSpace = CGColorSpace(name: usesFloatComponents
                  ? CGColorSpace.extendedLinearDisplayP3
                  : CGColorSpace.displayP3) else {
            bytesPerRow = 0
            pixelColorSpace = nil
            pixelData = nil
            return
        }
        bytesPerRow = rowBytes
        pixelColorSpace = colorSpace
        var data = Data(count: byteCount)
        let bitmapInfo = (usesFloatComponents
            ? CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGBitmapInfo.byteOrder32Big.rawValue)
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let rendered = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: image.width,
                      height: image.height,
                      bitsPerComponent: usesFloatComponents ? 16 : 8,
                      bytesPerRow: rowBytes,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.flush()
            return true
        }
        pixelData = rendered ? data : nil
    }

    static func imagePixel(
        at point: CGPoint,
        in bounds: CGRect,
        imageSize: CGSize
    ) -> ScreenshotPixelCoordinate? {
        guard bounds.width > 0, bounds.height > 0,
              imageSize.width >= 1, imageSize.height >= 1,
              point.x >= bounds.minX, point.x <= bounds.maxX,
              point.y >= bounds.minY, point.y <= bounds.maxY else {
            return nil
        }
        let column = Int(((point.x - bounds.minX) / bounds.width * imageSize.width).rounded(.down))
        let row = Int(((bounds.maxY - point.y) / bounds.height * imageSize.height).rounded(.down))
        return ScreenshotPixelCoordinate(
            column: min(max(column, 0), Int(imageSize.width) - 1),
            row: min(max(row, 0), Int(imageSize.height) - 1)
        )
    }

    static func imagePixelRect(for rect: CGRect, in bounds: CGRect, imageSize: CGSize) -> CGRect? {
        guard bounds.width > 0, bounds.height > 0,
              imageSize.width >= 1, imageSize.height >= 1 else { return nil }
        let scaledRect = CGRect(
            x: (rect.minX - bounds.minX) * imageSize.width / bounds.width,
            y: (bounds.maxY - rect.maxY) * imageSize.height / bounds.height,
            width: rect.width * imageSize.width / bounds.width,
            height: rect.height * imageSize.height / bounds.height
        ).integral
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let pixelRect = scaledRect.intersection(imageBounds)
        return pixelRect.isNull || pixelRect.isEmpty ? nil : pixelRect
    }
    static func cursorRulerSegments(
        at cursorPoint: CGPoint,
        in bounds: CGRect
    ) -> [(start: CGPoint, end: CGPoint)]? {
        guard bounds.width > 0, bounds.height > 0,
              cursorPoint.x >= bounds.minX, cursorPoint.x <= bounds.maxX,
              cursorPoint.y >= bounds.minY, cursorPoint.y <= bounds.maxY else { return nil }
        return [
            (CGPoint(x: bounds.minX, y: cursorPoint.y), cursorPoint),
            (cursorPoint, CGPoint(x: bounds.maxX, y: cursorPoint.y)),
            (CGPoint(x: cursorPoint.x, y: bounds.minY), cursorPoint),
            (cursorPoint, CGPoint(x: cursorPoint.x, y: bounds.maxY))
        ]
    }

    func sample(at coordinate: ScreenshotPixelCoordinate) -> ScreenshotPixelSample? {
        guard let components = pixelComponents(at: coordinate),
              let pixelColorSpace,
              let cgColor = CGColor(colorSpace: pixelColorSpace, components: components.map { CGFloat($0) }),
              let color = NSColor(cgColor: cgColor),
              let srgb = color.usingColorSpace(.sRGB),
              let displayP3 = color.usingColorSpace(.displayP3) else {
            return nil
        }
        let srgbBytes = self.components(of: srgb).map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        let srgbRGB = ScreenshotPixelRGB(red: srgbBytes[0], green: srgbBytes[1], blue: srgbBytes[2])
        return ScreenshotPixelSample(
            coordinate: coordinate,
            srgb: srgbRGB,
            displayP3Value: Self.formatted(self.components(of: displayP3)),
            relativeEDRValue: exposesRelativeEDR ? Self.formatted(Array(components.prefix(3))) : nil
        )
    }

    func magnifierColor(at coordinate: ScreenshotPixelCoordinate) -> NSColor? {
        guard let components = pixelComponents(at: coordinate),
              let pixelColorSpace,
              let cgColor = CGColor(colorSpace: pixelColorSpace, components: components.map { CGFloat($0) }),
              let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else {
            return nil
        }
        return NSColor(
            srgbRed: min(max(color.redComponent, 0), 1),
            green: min(max(color.greenComponent, 0), 1),
            blue: min(max(color.blueComponent, 0), 1),
            alpha: 1
        )
    }

    private func pixelComponents(at coordinate: ScreenshotPixelCoordinate) -> [Double]? {
        guard coordinate.column >= 0, coordinate.row >= 0,
              coordinate.column < Int(imageSize.width), coordinate.row < Int(imageSize.height),
              let pixelData else { return nil }
        let rowOffset = coordinate.row * bytesPerRow
        let offset = rowOffset + coordinate.column * bytesPerPixel
        let values = pixelData.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> [Double]? in
            guard let baseAddress = buffer.baseAddress else { return nil }
            if usesFloatComponents {
                let channels = baseAddress.assumingMemoryBound(to: UInt16.self).advanced(by: offset / 2)
                return (0..<4).map { Self.binary16Value(channels[$0]) }
            }
            let channels = baseAddress.assumingMemoryBound(to: UInt8.self).advanced(by: offset)
            return (0..<4).map { Double(channels[$0]) / 255 }
        }
        guard let values, values.count == 4 else { return nil }
        let alpha = values[3]
        guard alpha > 0 else { return [0, 0, 0, 0] }
        return [values[0] / alpha, values[1] / alpha, values[2] / alpha, alpha]
    }

    private static func binary16Value(_ bitPattern: UInt16) -> Double {
        let sign = UInt32(bitPattern & 0x8000) << 16
        let exponent = UInt32((bitPattern >> 10) & 0x1F)
        let fraction = UInt32(bitPattern & 0x03FF)
        if exponent == 0, fraction == 0 {
            return Double(Float(bitPattern: sign))
        }

        let floatBits: UInt32
        if exponent == 0 {
            var normalizedFraction = fraction
            var unbiasedExponent: Int32 = -14
            while (normalizedFraction & 0x0400) == 0 {
                normalizedFraction <<= 1
                unbiasedExponent -= 1
            }
            normalizedFraction &= 0x03FF
            let floatExponent = UInt32(unbiasedExponent + 127)
            floatBits = sign | (floatExponent << 23) | (normalizedFraction << 13)
        } else if exponent == 0x1F {
            floatBits = sign | 0x7F80_0000 | (fraction << 13)
        } else {
            floatBits = sign | ((exponent + 112) << 23) | (fraction << 13)
        }
        return Double(Float(bitPattern: floatBits))
    }

    private func components(of color: NSColor) -> [Double] {
        [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
    }

    private static func formatted(_ components: [Double]) -> String {
        guard components.count == 3 else { return "—" }
        return String(
            format: "%.3f, %.3f, %.3f",
            locale: Locale(identifier: "en_US_POSIX"),
            components[0], components[1], components[2]
        )
    }
}
