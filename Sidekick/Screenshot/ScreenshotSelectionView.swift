import AppKit
import CoreGraphics
final class ScreenshotSelectionView: NSView {
    private enum Mode {
        case region
        case window
    }

    private let image: CGImage
    private let windowTargets: [ScreenshotWindowTarget]?
    private let inspectionHUD: ScreenshotPixelInspectionHUD
    private let imageLayer = CALayer()
    private let shadeLayer = CALayer()
    private let shadeMask = CAShapeLayer()
    private let selectionBorder = CAShapeLayer()
    private let cursorRulerLayer = CAShapeLayer()
    private let instructionLayer = CATextLayer()
    private var mode = Mode.region
    private var selectionAspectRatio = ScreenshotAspectRatio.free
    private var dragStart: NSPoint?
    private var cursorPoint: NSPoint?
    private var selection = NSRect.zero
    private var hoveredWindow: ScreenshotWindowTarget?
    var choiceContinuation: AsyncStream<ScreenshotSelectionChoice>.Continuation?
    private var hasFinishedSelection = false
    private var isCopyingPixelValues = false
    private var isCapturingWindow = false

    init(frame: NSRect, image: CGImage, windowTargets: [ScreenshotWindowTarget]?) {
        self.image = image
        self.windowTargets = windowTargets
        inspectionHUD = ScreenshotPixelInspectionHUD(image: image)
        super.init(frame: frame)
        wantsLayer = true

        imageLayer.contents = image
        imageLayer.contentsGravity = .resize
        layer?.addSublayer(imageLayer)

        shadeLayer.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        shadeMask.fillColor = NSColor.white.cgColor
        shadeMask.fillRule = .evenOdd
        shadeLayer.mask = shadeMask
        layer?.addSublayer(shadeLayer)

        selectionBorder.fillColor = nil
        selectionBorder.strokeColor = NSColor.white.cgColor
        selectionBorder.lineWidth = 1
        layer?.addSublayer(selectionBorder)

        cursorRulerLayer.fillColor = nil
        cursorRulerLayer.strokeColor = NSColor.white.withAlphaComponent(0.65).cgColor
        cursorRulerLayer.lineWidth = 1
        layer?.addSublayer(cursorRulerLayer)

        instructionLayer.string = [
            "A next • Shift-A previous • C copies all •",
            "Drag region • Hover pixels • W windows • Return • Esc"
        ].joined(separator: " ")
        instructionLayer.font = NSFont.systemFont(ofSize: 14)
        instructionLayer.fontSize = 14
        instructionLayer.foregroundColor = NSColor.white.cgColor
        layer?.addSublayer(instructionLayer)
        layer?.addSublayer(inspectionHUD.layer)
        updateLayerFrames()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout()
        updateLayerFrames()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayerFrames()
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isCapturingWindow else { return }
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        if mode == .window {
            updateHoveredWindow(at: point)
        } else {
            updateSelectionLayers()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isCapturingWindow else { return }
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        updateSelectionLayers()
        if inspectionHUD.contains(point) {
            if let value = inspectionHUD.copiedValue(at: point) {
                send(.copiedPixelValue(value))
            }
            return
        }
        if mode == .window {
            switch ScreenshotWindowTargeting.selection(at: point, from: windowTargets ?? []) {
            case .none:
                return
            case .unavailable:
                send(.windowUnavailable)
            case let .selected(target):
                send(.windowSelected(target.windowID))
            }
            return
        }
        dragStart = point
        selection = .zero
        updateSelectionLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isCapturingWindow, mode == .region, let dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        selection = selectionAspectRatio.selectionRect(
            from: dragStart,
            to: point,
            in: bounds,
            imageSize: CGSize(width: image.width, height: image.height)
        )
        updateSelectionLayers()
    }

    override func mouseUp(with event: NSEvent) {
        guard !isCapturingWindow, mode == .region, let dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        cursorPoint = end
        let rect = selectionAspectRatio.selectionRect(
            from: dragStart,
            to: end,
            in: bounds,
            imageSize: CGSize(width: image.width, height: image.height)
        )
        self.dragStart = nil
        selection = rect.width < 2 || rect.height < 2 ? bounds : rect
        updateSelectionLayers()
        finishSelection(selection)
    }

    private func copyAllPixelValues() {
        guard let value = inspectionHUD.allValuesForKeyboardCopy() else { return }
        send(.copyPixelValues(value))
    }

    private func send(_ choice: ScreenshotSelectionChoice) {
        guard !hasFinishedSelection else { return }
        if case .copyPixelValues = choice {
            guard !isCopyingPixelValues else { return }
            isCopyingPixelValues = true
        } else {
            hasFinishedSelection = true
        }
        choiceContinuation?.yield(choice)
    }

    func pixelValueCopyFinished(didCopy: Bool) {
        inspectionHUD.showCopyFeedback(didCopy: didCopy)
        isCopyingPixelValues = false
    }
    private func cycleAspectRatio(reverse: Bool = false) {
        selectionAspectRatio = reverse ? selectionAspectRatio.previous : selectionAspectRatio.next
        if let dragStart, let cursorPoint {
            selection = selectionAspectRatio.selectionRect(
                from: dragStart,
                to: cursorPoint,
                in: bounds,
                imageSize: CGSize(width: image.width, height: image.height)
            )
        }
        updateSelectionLayers()
    }

    private func handleKeyAction(_ event: NSEvent) -> Bool {
        guard !isCapturingWindow else { return true }
        switch event.keyCode {
        case 8: copyAllPixelValues()
        case 0 where event.modifierFlags.contains(.shift): cycleAspectRatio(reverse: true)
        case 0: cycleAspectRatio()
        case 13: selectWindowMode()
        case 15: selectRegionMode()
        case 36, 76: finishSelection(bounds)
        case 53: send(.cancelled)
        default: return false
        }
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard handleKeyAction(event) else { return super.performKeyEquivalent(with: event) }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard handleKeyAction(event) else {
            super.keyDown(with: event)
            return
        }
    }

    private func selectWindowMode() {
        guard let windowTargets, !windowTargets.isEmpty else {
            send(.windowUnavailable)
            return
        }
        mode = .window
        instructionLayer.string = "A next • Shift-A previous • C copies all • Click window • R region • Return • Esc"
        selection = .zero
        hoveredWindow = nil
        updateSelectionLayers()
    }
    func beginWindowCapture(_ target: ScreenshotWindowTarget) {
        isCapturingWindow = true
        mode = .window
        selection = target.bounds
        hoveredWindow = target
        instructionLayer.string = "Capturing selected window…"
        updateSelectionLayers()
    }

    private func selectRegionMode() {
        mode = .region
        instructionLayer.string = [
            "A next • Shift-A previous • C copies all •",
            "Hover pixels • Drag region • W windows • Return • Esc"
        ].joined(separator: " ")
        selection = .zero
        hoveredWindow = nil
        updateSelectionLayers()
    }

    private func updateHoveredWindow(at point: NSPoint) {
        hoveredWindow = windowTargets?.first(where: { $0.bounds.contains(point) })
        selection = hoveredWindow?.bounds ?? .zero
        updateSelectionLayers()
    }

    private func finishSelection(_ rect: NSRect?) {
        guard let rect else {
            send(.cancelled)
            return
        }
        guard let pixelRect = ScreenshotPixelInspector.imagePixelRect(
            for: rect,
            in: bounds,
            imageSize: CGSize(width: image.width, height: image.height)
        ), let selectedImage = image.cropping(to: pixelRect) else {
            send(.cropFailed)
            return
        }
        send(.selected(selectedImage))
    }

    private func updateLayerFrames() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        imageLayer.contentsScale = window?.backingScaleFactor ?? 1
        shadeLayer.frame = bounds
        shadeMask.frame = bounds
        selectionBorder.frame = bounds
        cursorRulerLayer.frame = bounds
        instructionLayer.frame = CGRect(x: 24, y: 24, width: max(0, bounds.width - 48), height: 24)
        instructionLayer.contentsScale = window?.backingScaleFactor ?? 1
        CATransaction.commit()
        updateSelectionLayers()
    }

    private func updateSelectionLayers() {
        let path = CGMutablePath()
        path.addRect(bounds)
        if !selection.isEmpty { path.addRect(selection) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadeMask.path = path
        selectionBorder.path = selection.isEmpty ? nil : CGPath(rect: selection, transform: nil)
        selectionBorder.strokeColor = hoveredWindow.map {
            $0.isSelectable ? NSColor.white.cgColor : NSColor.systemRed.cgColor
        } ?? NSColor.white.cgColor
        CATransaction.commit()
        let rulerPoint = currentRulerPoint()
        updateCursorRulers(at: rulerPoint)
        inspectionHUD.update(
            cursorPoint: cursorPoint,
            viewBounds: bounds,
            selection: selection.isEmpty ? nil : selection,
            backingScale: window?.backingScaleFactor ?? 1,
            aspectRatio: selectionAspectRatio.rawValue,
            rulerPoint: rulerPoint,
            isDragging: dragStart != nil
        )

    }

    private func currentRulerPoint() -> CGPoint? {
        guard let cursorPoint else { return nil }
        guard mode == .region, let dragStart, !selection.isEmpty else { return cursorPoint }
        return selectionAspectRatio.selectionCorner(from: dragStart, to: cursorPoint, selection: selection)
    }

    private func updateCursorRulers(at rulerPoint: CGPoint?) {
        guard let rulerPoint,
              let segments = ScreenshotPixelInspector.cursorRulerSegments(at: rulerPoint, in: bounds) else {
            cursorRulerLayer.path = nil
            return
        }
        let xScale = bounds.width / CGFloat(image.width)
        let yScale = bounds.height / CGFloat(image.height)
        let path = CGMutablePath()
        segments.forEach { segment in
            path.move(to: segment.start)
            path.addLine(to: segment.end)
        }
        for tick in stride(from: 100, through: image.width, by: 100) {
            let rulerX = bounds.minX + CGFloat(tick) * xScale
            let length: CGFloat = tick.isMultiple(of: 500) ? 8 : 4
            path.move(to: CGPoint(x: rulerX, y: rulerPoint.y - length))
            path.addLine(to: CGPoint(x: rulerX, y: rulerPoint.y + length))
        }
        for tick in stride(from: 100, through: image.height, by: 100) {
            let rulerY = bounds.maxY - CGFloat(tick) * yScale
            let length: CGFloat = tick.isMultiple(of: 500) ? 8 : 4
            path.move(to: CGPoint(x: rulerPoint.x - length, y: rulerY))
            path.addLine(to: CGPoint(x: rulerPoint.x + length, y: rulerY))
        }
        cursorRulerLayer.path = path
    }
}
