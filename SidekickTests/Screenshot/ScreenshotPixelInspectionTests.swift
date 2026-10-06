import AppKit
import XCTest

@MainActor
final class ScreenshotPixelInspectionTests: XCTestCase {
    func testScreenshotPixelCoordinatesScaleAndClampImageEdges() {
        let bounds = CGRect(x: 20, y: 40, width: 800, height: 400)
        let imageSize = CGSize(width: 1_600, height: 800)

        XCTAssertEqual(
            ScreenshotPixelInspector.imagePixel(
                at: CGPoint(x: 220, y: 340),
                in: bounds,
                imageSize: imageSize
            ),
            ScreenshotPixelCoordinate(column: 400, row: 200)
        )
        XCTAssertEqual(
            ScreenshotPixelInspector.imagePixel(at: CGPoint(x: 20, y: 40), in: bounds, imageSize: imageSize),
            ScreenshotPixelCoordinate(column: 0, row: 799)
        )
        XCTAssertEqual(
            ScreenshotPixelInspector.imagePixel(at: CGPoint(x: 820, y: 440), in: bounds, imageSize: imageSize),
            ScreenshotPixelCoordinate(column: 1_599, row: 0)
        )
        XCTAssertNil(
            ScreenshotPixelInspector.imagePixel(at: CGPoint(x: 19.9, y: 40), in: bounds, imageSize: imageSize)
        )
    }

    func testAspectRatioPresetsConstrainPixelDimensionsAndReverseDrags() {
        let bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let imageSize = CGSize(width: 3_840, height: 2_160)
        let ratio = ScreenshotAspectRatio.sixteenByNine

        XCTAssertEqual(
            ratio.selectionRect(
                from: CGPoint(x: 100, y: 100),
                to: CGPoint(x: 500, y: 200),
                in: bounds,
                imageSize: imageSize
            ),
            CGRect(x: 100, y: 100, width: 400, height: 225)
        )
        XCTAssertEqual(
            ratio.selectionRect(
                from: CGPoint(x: 500, y: 400),
                to: CGPoint(x: 100, y: 300),
                in: bounds,
                imageSize: imageSize
            ),
            CGRect(x: 100, y: 175, width: 400, height: 225)
        )
        XCTAssertEqual(
            ScreenshotAspectRatio.allCases.map(\.rawValue),
            ["Free", "1:1", "4:3", "3:2", "16:9", "9:16"]
        )
        XCTAssertEqual(
            ScreenshotAspectRatio.allCases.map(\.next),
            [.square, .fourByThree, .threeByTwo, .sixteenByNine, .nineBySixteen, .free]
        )
        XCTAssertEqual(
            ScreenshotAspectRatio.allCases.map(\.previous),
            [.nineBySixteen, .free, .square, .fourByThree, .threeByTwo, .sixteenByNine]
        )
    }

    func testAspectRatioSelectionUsesPixelScaleAndStaysInsideDisplay() {
        let nonuniformBounds = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        let nonuniformImageSize = CGSize(width: 2_000, height: 1_000)
        XCTAssertEqual(
            ScreenshotAspectRatio.square.selectionRect(
                from: CGPoint(x: 100, y: 100),
                to: CGPoint(x: 150, y: 200),
                in: nonuniformBounds,
                imageSize: nonuniformImageSize
            ),
            CGRect(x: 100, y: 100, width: 50, height: 100)
        )

        let bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        XCTAssertEqual(
            ScreenshotAspectRatio.square.selectionRect(
                from: CGPoint(x: 1_900, y: 1_060),
                to: CGPoint(x: 1_950, y: 1_100),
                in: bounds,
                imageSize: CGSize(width: 3_840, height: 2_160)
            ),
            CGRect(x: 1_900, y: 1_060, width: 20, height: 20)
        )
    }

    func testScreenshotSelectionPixelRectMatchesIntegralCropDimensions() {
        let bounds = CGRect(x: 20, y: 40, width: 800, height: 400)
        let selection = CGRect(x: 20.25, y: 40.2, width: 50.2, height: 20.2)

        XCTAssertEqual(
            ScreenshotPixelInspector.imagePixelRect(
                for: selection,
                in: bounds,
                imageSize: CGSize(width: 1_600, height: 800)
            ),
            CGRect(x: 0, y: 759, width: 101, height: 41)
        )
    }

    func testCursorRulersReachAllFourDisplayEdges() throws {
        let bounds = CGRect(x: 10, y: 20, width: 100, height: 80)
        let cursorPoint = CGPoint(x: 50, y: 60)
        let segments = try XCTUnwrap(ScreenshotPixelInspector.cursorRulerSegments(at: cursorPoint, in: bounds))

        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments[0].start, CGPoint(x: 10, y: 60))
        XCTAssertEqual(segments[0].end, cursorPoint)
        XCTAssertEqual(segments[1].start, cursorPoint)
        XCTAssertEqual(segments[1].end, CGPoint(x: 110, y: 60))
        XCTAssertEqual(segments[2].start, CGPoint(x: 50, y: 20))
        XCTAssertEqual(segments[2].end, cursorPoint)
        XCTAssertEqual(segments[3].start, cursorPoint)
        XCTAssertEqual(segments[3].end, CGPoint(x: 50, y: 100))
    }

    func testInspectionHUDTracksCursorAndStaysPutForValueClicks() throws {
        let image = try XCTUnwrap(makeDisplayP3PixelImage())
        let hud = ScreenshotPixelInspectionHUD(image: image)
        let bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        hud.update(cursorPoint: CGPoint(x: 800, y: 400), viewBounds: bounds, selection: nil, backingScale: 1)
        let initialFrame = hud.layer.frame

        XCTAssertEqual(initialFrame, CGRect(x: 824, y: 424, width: 264, height: 174))
        hud.update(cursorPoint: CGPoint(x: 840, y: 440), viewBounds: bounds, selection: nil, backingScale: 1)
        XCTAssertEqual(hud.layer.frame, initialFrame)
        hud.update(cursorPoint: CGPoint(x: 1_910, y: 1_070), viewBounds: bounds, selection: nil, backingScale: 1)
        XCTAssertEqual(hud.layer.frame, CGRect(x: 1_622, y: 872, width: 264, height: 174))
    }

    func testAspectRatioRulersFollowTheConstrainedSelectionCorner() {
        let ratio = ScreenshotAspectRatio.sixteenByNine
        let bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        let start = CGPoint(x: 100, y: 100)
        let end = CGPoint(x: 500, y: 200)
        let selection = ratio.selectionRect(
            from: start,
            to: end,
            in: bounds,
            imageSize: CGSize(width: 3_840, height: 2_160)
        )

        XCTAssertEqual(ratio.selectionCorner(from: start, to: end, selection: selection), CGPoint(x: 500, y: 325))
    }

    func testInspectionHUDMovesOffSelectionAndRulerLinesDuringDrag() throws {
        let image = try XCTUnwrap(makeDisplayP3PixelImage())
        let hud = ScreenshotPixelInspectionHUD(image: image)
        let bounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
        hud.update(
            cursorPoint: CGPoint(x: 800, y: 400),
            viewBounds: bounds,
            selection: CGRect(x: 900, y: 400, width: 500, height: 500),
            backingScale: 1,
            aspectRatio: "16:9",
            rulerPoint: CGPoint(x: 500, y: 325),
            isDragging: true
        )

        XCTAssertEqual(hud.layer.frame, CGRect(x: 512, y: 424, width: 264, height: 174))
    }

    func testScreenshotPixelSamplePreservesDisplayP3AndDoesNotInventEDR() throws {
        let image = try XCTUnwrap(makeDisplayP3PixelImage())
        let inspector = ScreenshotPixelInspector(image: image)

        let sample = try XCTUnwrap(inspector.sample(at: ScreenshotPixelCoordinate(column: 0, row: 0)))

        XCTAssertEqual(sample.displayP3Value, "0.200, 0.400, 0.800")
        XCTAssertEqual(sample.hex.count, 7)
        XCTAssertNil(sample.relativeEDRValue)
    }

    func testScreenshotPixelSampleExposesRelativeEDROnExtendedSource() throws {
        let image = try XCTUnwrap(makeExtendedLinearPixelImage())
        let inspector = ScreenshotPixelInspector(image: image)

        let sample = try XCTUnwrap(inspector.sample(at: ScreenshotPixelCoordinate(column: 0, row: 0)))

        let components = try XCTUnwrap(sample.relativeEDRValue).components(separatedBy: ", ").compactMap(Double.init)
        XCTAssertEqual(components.count, 3)
        XCTAssertGreaterThan(components[0], 1)
        XCTAssertEqual(components[1], 0.5, accuracy: 0.01)
        XCTAssertEqual(components[2], 0.25, accuracy: 0.01)
    }

    func testScreenshotInspectionHUDCopiesValuesAndReportsSelectionSize() throws {
        let image = try XCTUnwrap(makeDisplayP3PixelImage())
        let hud = ScreenshotPixelInspectionHUD(image: image)
        let viewBounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        hud.update(
            cursorPoint: CGPoint(x: 100, y: 150),
            viewBounds: viewBounds,
            selection: CGRect(x: 0, y: 0, width: 200, height: 150),
            backingScale: 1
        )

        let hexClick = CGPoint(x: hud.layer.frame.minX + 110, y: hud.layer.frame.minY + 134)
        let coordinateClick = CGPoint(x: hud.layer.frame.minX + 110, y: hud.layer.frame.minY + 155)
        let selectionClick = CGPoint(x: hud.layer.frame.minX + 20, y: hud.layer.frame.minY + 22)

        let sample = try XCTUnwrap(
            ScreenshotPixelInspector(image: image).sample(
                at: ScreenshotPixelCoordinate(column: 0, row: 1)
            )
        )
        let allValues = [
            "Pixel: 0, 1",
            "HEX: \(sample.hex)",
            "sRGB: \(sample.srgbValue)",
            "Display P3: \(sample.displayP3Value)",
            "EDR RGB: unavailable (SDR)",
            "Selection: 1 × 1 px"
        ].joined(separator: "\n")
        XCTAssertEqual(hud.allValuesForKeyboardCopy(), allValues)
        XCTAssertFalse(hud.isShowingCopyFeedback)
        hud.showCopyFeedback(didCopy: true)
        XCTAssertTrue(hud.isShowingCopyFeedback)
        hud.update(
            cursorPoint: CGPoint(x: 100, y: 150),
            viewBounds: viewBounds,
            selection: CGRect(x: 0, y: 0, width: 200, height: 150),
            backingScale: 1
        )
        XCTAssertFalse(hud.isShowingCopyFeedback)
        XCTAssertEqual(hud.copiedValue(at: hexClick), sample.hex)
        XCTAssertEqual(hud.copiedValue(at: coordinateClick), "0, 1")
        XCTAssertEqual(hud.copiedValue(at: selectionClick), "1 × 1")
        hud.showCopyFeedback(didCopy: false)
        XCTAssertFalse(hud.isShowingCopyFeedback)
        XCTAssertTrue(hud.isShowingCopyFailure)
        hud.update(
            cursorPoint: CGPoint(x: 100, y: 150),
            viewBounds: viewBounds,
            selection: CGRect(x: 0, y: 0, width: 200, height: 150),
            backingScale: 1
        )
        XCTAssertTrue(hud.isShowingCopyFailure)
    }

    func testScreenshotPixelSamplesUseTopLeftImageCoordinates() throws {
        let image = try XCTUnwrap(makeVerticalPixelImage())
        let inspector = ScreenshotPixelInspector(image: image)

        let topPixel = try XCTUnwrap(inspector.sample(at: ScreenshotPixelCoordinate(column: 0, row: 0)))
        let bottomPixel = try XCTUnwrap(inspector.sample(at: ScreenshotPixelCoordinate(column: 0, row: 1)))

        XCTAssertEqual(topPixel.hex, "#FF0000")
        XCTAssertEqual(bottomPixel.hex, "#0000FF")
    }

    private func makeVerticalPixelImage() -> CGImage? {
        let bytes: [UInt8] = [255, 0, 0, 255, 0, 0, 255, 255]
        let data = bytes.withUnsafeBytes { Data($0) }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return CGImage(
            width: 1,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func makeDisplayP3PixelImage() -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let color = CGColor(colorSpace: colorSpace, components: [0.2, 0.4, 0.8, 1]),
              let context = CGContext(
                  data: nil,
                  width: 2,
                  height: 2,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return context.makeImage()
    }

    private func makeExtendedLinearPixelImage() -> CGImage? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
        let channels: [UInt16] = [
            Float16(1.5).bitPattern,
            Float16(0.5).bitPattern,
            Float16(0.25).bitPattern,
            Float16(1).bitPattern
        ]
        let data = channels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return CGImage(
            width: 1,
            height: 1,
            bitsPerComponent: 16,
            bitsPerPixel: 64,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
