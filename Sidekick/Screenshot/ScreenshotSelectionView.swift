import AppKit
import CoreGraphics
final class ScreenshotSelectionView: NSView {

    private let image: CGImage
    private let inspectionHUD: ScreenshotPixelInspectionHUD
    private let imageLayer = CALayer()
    private let shadeLayer = CALayer()
    private let shadeMask = CAShapeLayer()
    private let selectionBorder = CAShapeLayer()
    private let cursorRulerLayer = CAShapeLayer()
    private let instructionLayer = CATextLayer()
    private var selectionAspectRatio = ScreenshotAspectRatio.free
    private var dragStart: NSPoint?
    private var cursorPoint: NSPoint?
    private var selection = NSRect.zero
    private let saveAndCopyButton = NSButton(title: "Save & Copy", target: nil, action: nil)
    var choiceContinuation: AsyncStream<ScreenshotSelectionChoice>.Continuation?
    private var hasFinishedSelection = false
    private var isCopyingPixelValues = false

    init(frame: NSRect, image: CGImage) {
        self.image = image
        inspectionHUD = ScreenshotPixelInspectionHUD(image: image)
        super.init(frame: frame)
        wantsLayer = true
        saveAndCopyButton.target = self
        saveAndCopyButton.action = #selector(saveAndCopySelection)
        saveAndCopyButton.setAccessibilityLabel("Save and copy screenshot")
        addSubview(saveAndCopyButton)

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
            "W window • C copies area (full screen if none) • Shift-C pixel details • F full screen •",
            "Drag region • Save & Copy • Return • Esc"
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
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        updateSelectionLayers()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        updateSelectionLayers()
        if inspectionHUD.contains(point) {
            if let value = inspectionHUD.copiedValue(at: point) {
                send(.copiedPixelValue(value))
            }
            return
        }
        dragStart = point
        selection = .zero
        updateSelectionLayers()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
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
        guard let dragStart else { return }
        let end = convert(event.locationInWindow, from: nil)
        cursorPoint = end
        let rect = selectionAspectRatio.selectionRect(
            from: dragStart,
            to: end,
            in: bounds,
            imageSize: CGSize(width: image.width, height: image.height)
        )
        self.dragStart = nil
        selection = rect.width < 2 || rect.height < 2 ? .zero : rect
        updateSelectionLayers()
    }

    private func copySelectionOnly() {
        let rect = selection.isEmpty ? bounds : selection
        guard let selectedImage = selectedImage(in: rect) else { return }
        send(.copyOnly(selectedImage))
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
        if handlePixelCopyKey(event) { return true }
        switch event.keyCode {
        case 13: send(.windowCapture)
        case 3: finishFullDisplay()
        case 0 where event.modifierFlags.contains(.shift): cycleAspectRatio(reverse: true)
        case 0: cycleAspectRatio()
        case 36, 76: acceptSelection()
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

    private func acceptSelection(forceSaveAndCopy: Bool = false) {
        finishSelection(selection.isEmpty ? bounds : selection, forceSaveAndCopy: forceSaveAndCopy)
    }

    private func finishFullDisplay() {
        selection = bounds
        updateSelectionLayers()
        finishSelection(bounds)
    }

    @objc func saveAndCopySelection() {
        acceptSelection(forceSaveAndCopy: true)
    }

    private func finishSelection(_ rect: NSRect, forceSaveAndCopy: Bool = false) {
        guard let selectedImage = selectedImage(in: rect) else { return }
        send(forceSaveAndCopy ? .saveAndCopy(selectedImage) : .selected(selectedImage))
    }

    private func selectedImage(in rect: NSRect) -> CGImage? {
        guard let selectedImage = screenshotCrop(image, in: rect, bounds: bounds) else {
            send(.cropFailed)
            return nil
        }
        return selectedImage
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
        let buttonSize = saveAndCopyButton.fittingSize
        saveAndCopyButton.frame = NSRect(
            x: max(bounds.minX + 24, bounds.maxX - buttonSize.width - 24),
            y: bounds.maxY - buttonSize.height - 24,
            width: buttonSize.width,
            height: buttonSize.height
        )
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
        selectionBorder.strokeColor = NSColor.white.cgColor
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
        guard let dragStart, !selection.isEmpty else { return cursorPoint }
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

private extension ScreenshotSelectionView {
    func copyAllPixelValues() {
        guard let value = inspectionHUD.allValuesForKeyboardCopy() else { return }
        send(.copyPixelValues(value))
    }

    func handlePixelCopyKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 8 else { return false }
        if event.modifierFlags.contains(.shift) {
            copyAllPixelValues()
        } else {
            copySelectionOnly()
        }
        return true
    }
}
@MainActor
private func screenshotCrop(_ image: CGImage, in rect: NSRect, bounds: NSRect) -> CGImage? {
    guard let pixelRect = ScreenshotPixelInspector.imagePixelRect(
        for: rect,
        in: bounds,
        imageSize: CGSize(width: image.width, height: image.height)
    ) else {
        return nil
    }
    return image.cropping(to: pixelRect)
}
