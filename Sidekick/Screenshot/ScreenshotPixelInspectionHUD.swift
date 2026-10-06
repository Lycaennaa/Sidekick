import AppKit
import CoreGraphics
@MainActor
final class ScreenshotPixelInspectionHUD {
    private static let size = CGSize(width: 264, height: 174)
    private static let gridOrigin = CGPoint(x: 10, y: 52)
    private static let cellSize: CGFloat = 8.5

    let layer = CALayer()
    private let inspector: ScreenshotPixelInspector
    private let coordinateLayer = ScreenshotPixelInspectionHUD.makeTextLayer(fontSize: 12)
    private let hexLayer = ScreenshotPixelInspectionHUD.makeTextLayer(fontSize: 12)
    private let srgbLayer = ScreenshotPixelInspectionHUD.makeTextLayer(fontSize: 12)
    private let displayP3Layer = ScreenshotPixelInspectionHUD.makeTextLayer(fontSize: 12)
    private let edrLayer = ScreenshotPixelInspectionHUD.makeTextLayer(fontSize: 10)
    private let selectionLayer = ScreenshotPixelInspectionHUD.makeTextLayer(fontSize: 11)
    private let ratioLayer = ScreenshotPixelInspectionHUD.makeTextLayer(fontSize: 11)
    private let pixelLayers: [CALayer]
    private let centerBorderLayer = CALayer()
    private var sample: ScreenshotPixelSample?
    private var selectionValue: String?
    private struct Positioning {
        let cursorPoint: CGPoint?
        let rulerPoint: CGPoint?
        let isDragging: Bool
        let viewBounds: CGRect
        let selection: CGRect?
    }

    private enum CopyStatus: Equatable {
        case copied
        case failed
    }

    private var copyStatus: CopyStatus?
    var isShowingCopyFeedback: Bool { copyStatus == .copied }
    var isShowingCopyFailure: Bool { copyStatus == .failed }

    init(image: CGImage) {
        inspector = ScreenshotPixelInspector(image: image)
        pixelLayers = (0..<81).map { _ in
            let pixel = CALayer()
            pixel.borderWidth = 0.5
            pixel.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
            return pixel
        }
        layer.backgroundColor = NSColor(calibratedWhite: 0.04, alpha: 0.9).cgColor
        layer.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 12
        for (index, pixel) in pixelLayers.enumerated() {
            let row = index / 9
            let column = index % 9
            pixel.frame = CGRect(
                x: Self.gridOrigin.x + CGFloat(column) * Self.cellSize,
                y: Self.gridOrigin.y + CGFloat(8 - row) * Self.cellSize,
                width: Self.cellSize,
                height: Self.cellSize
            )
            layer.addSublayer(pixel)
        }
        centerBorderLayer.frame = CGRect(
            x: Self.gridOrigin.x + 4 * Self.cellSize,
            y: Self.gridOrigin.y + 4 * Self.cellSize,
            width: Self.cellSize,
            height: Self.cellSize
        )
        centerBorderLayer.borderColor = NSColor.systemYellow.cgColor
        centerBorderLayer.borderWidth = 2
        layer.addSublayer(centerBorderLayer)
        coordinateLayer.frame = CGRect(x: 96, y: 148, width: 158, height: 16)
        hexLayer.frame = CGRect(x: 96, y: 126, width: 158, height: 16)
        srgbLayer.frame = CGRect(x: 96, y: 106, width: 158, height: 16)
        displayP3Layer.frame = CGRect(x: 96, y: 86, width: 158, height: 16)
        edrLayer.frame = CGRect(x: 96, y: 66, width: 158, height: 16)
        selectionLayer.frame = CGRect(x: 10, y: 14, width: 156, height: 16)
        ratioLayer.frame = CGRect(x: 174, y: 14, width: 80, height: 16)
        [coordinateLayer, hexLayer, srgbLayer, displayP3Layer, edrLayer, selectionLayer, ratioLayer].forEach {
            layer.addSublayer($0)
        }

    }
    func update(
        cursorPoint: CGPoint?,
        viewBounds: CGRect,
        selection: CGRect?,
        backingScale: CGFloat,
        aspectRatio: String = "Free",
        rulerPoint: CGPoint? = nil,
        isDragging: Bool = false
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = min(Self.size.width, max(0, viewBounds.width - 32))
        let height = min(Self.size.height, max(0, viewBounds.height - 32))
        layer.frame = positionedFrame(
            Positioning(
                cursorPoint: cursorPoint,
                rulerPoint: rulerPoint,
                isDragging: isDragging,
                viewBounds: viewBounds,
                selection: selection
            ),
            width: width,
            height: height
        )
        layer.contentsScale = backingScale
        [coordinateLayer, hexLayer, srgbLayer, displayP3Layer, edrLayer, selectionLayer, ratioLayer].forEach {
            $0.contentsScale = backingScale
        }
        pixelLayers.forEach { $0.contentsScale = backingScale }
        updatePixelSample(cursorPoint: cursorPoint, viewBounds: viewBounds)
        updateSelectionValue(selection, in: viewBounds)
        updateCopyStatus(aspectRatio: aspectRatio)
        CATransaction.commit()
    }

    private func updatePixelSample(cursorPoint: CGPoint?, viewBounds: CGRect) {
        guard let cursorPoint,
              let coordinate = ScreenshotPixelInspector.imagePixel(
                at: cursorPoint,
                in: viewBounds,
                imageSize: inspector.imageSize
              ), let value = inspector.sample(at: coordinate) else {
            sample = nil
            coordinateLayer.string = "Move pointer to inspect"
            hexLayer.string = "HEX —"
            srgbLayer.string = "sRGB —"
            displayP3Layer.string = "P3 —"
            edrLayer.string = "EDR RGB unavailable (SDR)"
            pixelLayers.forEach { $0.backgroundColor = NSColor.black.cgColor }
            return
        }

        sample = value
        coordinateLayer.string = "Pixel \(coordinate.column), \(coordinate.row)"
        hexLayer.string = "HEX \(value.hex)"
        srgbLayer.string = "sRGB \(value.srgbValue.replacingOccurrences(of: ", ", with: " "))"
        displayP3Layer.string = "P3 \(value.displayP3Value.replacingOccurrences(of: ", ", with: " "))"
        let edrValue = value.relativeEDRValue?.replacingOccurrences(of: ", ", with: " ") ?? "unavailable (SDR)"
        edrLayer.string = "EDR RGB \(edrValue)"
        updateMagnifier(around: coordinate)
    }

    private func updateSelectionValue(_ selection: CGRect?, in viewBounds: CGRect) {
        if let selection,
           let pixelRect = ScreenshotPixelInspector.imagePixelRect(
               for: selection,
               in: viewBounds,
               imageSize: inspector.imageSize
           ) {
            let value = "\(Int(pixelRect.width)) × \(Int(pixelRect.height))"
            selectionValue = value
            selectionLayer.string = "Sel \(value) px"
        } else {
            selectionValue = nil
            selectionLayer.string = "Drag to measure"
        }
    }

    private func updateCopyStatus(aspectRatio: String) {
        if copyStatus == .failed {
            ratioLayer.string = "Copy failed"
        } else {
            ratioLayer.string = "A: \(aspectRatio)"
            copyStatus = nil
        }
    }

    func showCopyFeedback(didCopy: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        copyStatus = didCopy ? .copied : .failed
        ratioLayer.string = didCopy ? "Copied all" : "Copy failed"
        CATransaction.commit()
    }

    func copiedValue(at point: CGPoint) -> String? {
        let localPoint = CGPoint(x: point.x - layer.frame.minX, y: point.y - layer.frame.minY)
        guard layer.frame.contains(point) else { return nil }
        if coordinateLayer.frame.contains(localPoint), let sample {
            return "\(sample.coordinate.column), \(sample.coordinate.row)"
        }
        if hexLayer.frame.contains(localPoint) { return sample?.hex }
        if srgbLayer.frame.contains(localPoint) { return sample?.srgbValue }
        if displayP3Layer.frame.contains(localPoint) { return sample?.displayP3Value }
        if edrLayer.frame.contains(localPoint) { return sample?.relativeEDRValue }
        if selectionLayer.frame.contains(localPoint) { return selectionValue }
        return nil
    }
    func allValuesForKeyboardCopy() -> String? {
        guard let sample else { return nil }
        let edrValue = sample.relativeEDRValue ?? "unavailable (SDR)"
        let selectionDescription = selectionValue.map { "\($0) px" } ?? "not selected"
        return [
            "Pixel: \(sample.coordinate.column), \(sample.coordinate.row)",
            "HEX: \(sample.hex)",
            "sRGB: \(sample.srgbValue)",
            "Display P3: \(sample.displayP3Value)",
            "EDR RGB: \(edrValue)",
            "Selection: \(selectionDescription)"
        ].joined(separator: "\n")
    }

    func contains(_ point: CGPoint) -> Bool {
        layer.frame.contains(point)
    }

    private func positionedFrame(
        _ position: Positioning,
        width: CGFloat,
        height: CGFloat
    ) -> CGRect {
        let viewBounds = position.viewBounds
        let selection = position.selection
        if let cursorPoint = position.cursorPoint,
           !position.isDragging,
           layer.frame.size == CGSize(width: width, height: height),
           viewBounds.contains(layer.frame),
           layer.frame.contains(cursorPoint),
           !intersectsSelectionBorder(layer.frame, selection: selection) {
            return layer.frame
        }
        guard let cursorPoint = position.cursorPoint else {
            return CGRect(
                x: max(viewBounds.minX + 16, viewBounds.maxX - width - 24),
                y: max(viewBounds.minY + 16, viewBounds.maxY - height - 48),
                width: width,
                height: height
            )
        }
        let candidates = candidateFrames(
            around: cursorPoint,
            selection: selection,
            in: viewBounds,
            width: width,
            height: height
        )
        if let candidate = candidates.first(where: {
            viewBounds.contains($0)
                && !intersectsSelectionBorder($0, selection: selection)
                && !intersectsRuler($0, at: position.rulerPoint)
        }) {
            return candidate
        }
        let margin: CGFloat = 16
        let minX = viewBounds.minX + margin
        let minY = viewBounds.minY + margin
        let maxX = max(minX, viewBounds.maxX - width - margin)
        let maxY = max(minY, viewBounds.maxY - height - margin)
        return CGRect(
            x: min(max(cursorPoint.x + 24, minX), maxX),
            y: min(max(cursorPoint.y + 24, minY), maxY),
            width: width,
            height: height
        )
    }

    private func candidateFrames(
        around cursorPoint: CGPoint,
        selection: CGRect?,
        in viewBounds: CGRect,
        width: CGFloat,
        height: CGFloat
    ) -> [CGRect] {
        let offset: CGFloat = 24
        var candidates = [
            CGRect(x: cursorPoint.x + offset, y: cursorPoint.y + offset, width: width, height: height),
            CGRect(x: cursorPoint.x - width - offset, y: cursorPoint.y + offset, width: width, height: height),
            CGRect(x: cursorPoint.x + offset, y: cursorPoint.y - height - offset, width: width, height: height),
            CGRect(x: cursorPoint.x - width - offset, y: cursorPoint.y - height - offset, width: width, height: height)
        ]
        if let selection {
            candidates += [
                CGRect(x: selection.minX - width - offset, y: cursorPoint.y + offset, width: width, height: height),
                CGRect(x: selection.maxX + offset, y: cursorPoint.y + offset, width: width, height: height),
                CGRect(x: cursorPoint.x + offset, y: selection.maxY + offset, width: width, height: height),
                CGRect(x: cursorPoint.x + offset, y: selection.minY - height - offset, width: width, height: height)
            ]
        }
        let margin: CGFloat = 16
        candidates += [
            CGRect(x: viewBounds.minX + margin, y: viewBounds.maxY - height - margin, width: width, height: height),
            CGRect(
                x: viewBounds.maxX - width - margin,
                y: viewBounds.maxY - height - margin,
                width: width,
                height: height
            ),
            CGRect(x: viewBounds.minX + margin, y: viewBounds.minY + margin, width: width, height: height),
            CGRect(x: viewBounds.maxX - width - margin, y: viewBounds.minY + margin, width: width, height: height)
        ]
        return candidates
    }

    private func intersectsSelectionBorder(_ frame: CGRect, selection: CGRect?) -> Bool {
        guard let selection, !selection.isEmpty else { return false }
        let thickness: CGFloat = 2
        let horizontalEdges = [selection.minY, selection.maxY].map { edge in
            CGRect(
                x: selection.minX - thickness,
                y: edge - thickness / 2,
                width: selection.width + 2 * thickness,
                height: thickness
            )
        }
        let verticalEdges = [selection.minX, selection.maxX].map { edge in
            CGRect(
                x: edge - thickness / 2,
                y: selection.minY - thickness,
                width: thickness,
                height: selection.height + 2 * thickness
            )
        }
        return (horizontalEdges + verticalEdges).contains { $0.intersects(frame) }
    }

    private func intersectsRuler(_ frame: CGRect, at point: CGPoint?) -> Bool {
        guard let point else { return false }
        return (point.x >= frame.minX && point.x <= frame.maxX)
            || (point.y >= frame.minY && point.y <= frame.maxY)
    }

    private func updateMagnifier(around center: ScreenshotPixelCoordinate) {
        for (index, pixel) in pixelLayers.enumerated() {
            let row = index / 9
            let column = index % 9
            let coordinate = ScreenshotPixelCoordinate(
                column: center.column + column - 4,
                row: center.row + row - 4
            )
            pixel.backgroundColor = inspector.magnifierColor(at: coordinate)?.cgColor ?? NSColor.black.cgColor
        }
    }

    private static func makeTextLayer(fontSize: CGFloat) -> CATextLayer {
        let text = CATextLayer()
        text.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        text.fontSize = fontSize
        text.foregroundColor = NSColor.white.cgColor
        text.truncationMode = .end
        return text
    }
}
