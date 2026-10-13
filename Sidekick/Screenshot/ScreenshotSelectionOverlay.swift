import AppKit
import CoreGraphics
enum ScreenshotAspectRatio: String, CaseIterable {
    case free = "Free"
    case square = "1:1"
    case fourByThree = "4:3"
    case threeByTwo = "3:2"
    case sixteenByNine = "16:9"
    case nineBySixteen = "9:16"

    var pixelRatio: CGFloat? {
        switch self {
        case .free: nil
        case .square: 1
        case .fourByThree: 4 / 3
        case .threeByTwo: 3 / 2
        case .sixteenByNine: 16 / 9
        case .nineBySixteen: 9 / 16
        }
    }

    var next: ScreenshotAspectRatio {
        switch self {
        case .free: .square
        case .square: .fourByThree
        case .fourByThree: .threeByTwo
        case .threeByTwo: .sixteenByNine
        case .sixteenByNine: .nineBySixteen
        case .nineBySixteen: .free
        }
    }

    var previous: ScreenshotAspectRatio {
        switch self {
        case .free: .nineBySixteen
        case .square: .free
        case .fourByThree: .square
        case .threeByTwo: .fourByThree
        case .sixteenByNine: .threeByTwo
        case .nineBySixteen: .sixteenByNine
        }
    }

    func selectionCorner(from start: CGPoint, to end: CGPoint, selection: CGRect) -> CGPoint {
        CGPoint(
            x: end.x < start.x ? selection.minX : selection.maxX,
            y: end.y < start.y ? selection.minY : selection.maxY
        )
    }

    func selectionRect(
        from start: CGPoint,
        to end: CGPoint,
        in bounds: CGRect,
        imageSize: CGSize
    ) -> CGRect {
        let freeRect = CGRect(origin: start, size: .zero).union(CGRect(origin: end, size: .zero))
        guard let pixelRatio, bounds.width > 0, bounds.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return freeRect }
        let xScale = imageSize.width / bounds.width
        let yScale = imageSize.height / bounds.height
        let requestedWidth = max(abs(end.x - start.x) * xScale, abs(end.y - start.y) * yScale * pixelRatio)
        guard requestedWidth > 0 else { return freeRect }
        let requestedHeight = requestedWidth / pixelRatio
        let availableWidth = max(0, (end.x < start.x ? start.x - bounds.minX : bounds.maxX - start.x) * xScale)
        let availableHeight = max(0, (end.y < start.y ? start.y - bounds.minY : bounds.maxY - start.y) * yScale)
        let scale = min(1, min(availableWidth / requestedWidth, availableHeight / requestedHeight))
        let width = requestedWidth * scale / xScale
        let height = requestedHeight * scale / yScale
        return CGRect(
            x: end.x < start.x ? start.x - width : start.x,
            y: end.y < start.y ? start.y - height : start.y,
            width: width,
            height: height
        )
    }
}

enum ScreenshotSelectionChoice {
    case selected(CGImage)
    case copyOnly(CGImage)
    case saveAndCopy(CGImage)
    case copiedPixelValue(String)
    case copyPixelValues(String)
    case cancelled
    case displayUnavailable
    case cropFailed
}

@MainActor
enum ScreenshotSelectionOverlay {
    private struct ChoiceContext {
        let view: ScreenshotSelectionView
    }

    static func select(
        _ screenshot: CapturedDisplayScreenshot,
        copyPixelValues: ScreenshotPixelValueCopy
    ) async -> ScreenshotSelectionResult {
        guard let screen = NSScreen.screens.first(where: { $0.screenshotDisplayID == screenshot.displayID }),
              screen.frame == screenshot.screenFrame else {
            return .displayUnavailable
        }
        NSApp.activate(ignoringOtherApps: true)
        let window = ScreenshotSelectionWindow(
            contentRect: screenshot.screenFrame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.acceptsMouseMovedEvents = true
        let view = ScreenshotSelectionView(
            frame: NSRect(origin: .zero, size: screenshot.screenFrame.size),
            image: screenshot.image
        )
        let (choices, continuation) = AsyncStream<ScreenshotSelectionChoice>.makeStream(
            bufferingPolicy: .bufferingOldest(2)
        )
        view.choiceContinuation = continuation
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        defer {
            continuation.finish()
            view.choiceContinuation = nil
            window.orderOut(nil)
        }
        let context = ChoiceContext(view: view)
        let selectionResult: ScreenshotSelectionResult = await withTaskCancellationHandler {
            for await choice in choices {
                if let result = await resultForChoice(
                    for: choice,
                    context: context,
                    copyPixelValues: copyPixelValues
                ) {
                    return result
                }
            }
            return .cancelled
        } onCancel: {
            continuation.finish()
        }
        return selectionResult
    }

    private static func resultForChoice(
        for choice: ScreenshotSelectionChoice,
        context: ChoiceContext,
        copyPixelValues: ScreenshotPixelValueCopy
    ) async -> ScreenshotSelectionResult? {
        switch choice {
        case let .copyPixelValues(values):
            return await handlePixelValueCopies(values, context: context, copy: copyPixelValues)
        case let .copyOnly(image):
            return .copyOnly(image)
        case let .saveAndCopy(image):
            return .saveAndCopy(image)
        default:
            return simpleResult(for: choice)
        }
    }

    private static func handlePixelValueCopies(
        _ values: String,
        context: ChoiceContext,
        copy: ScreenshotPixelValueCopy
    ) async -> ScreenshotSelectionResult? {
        let copied = await copy(values)
        guard !Task.isCancelled else { return .cancelled }
        context.view.pixelValueCopyFinished(didCopy: copied)
        return nil
    }

    private static func simpleResult(for choice: ScreenshotSelectionChoice) -> ScreenshotSelectionResult? {
        switch choice {
        case let .selected(image):
            return .selected(image)
        case let .copiedPixelValue(value):
            return .copiedPixelValue(value)
        case .cancelled:
            return .cancelled
        case .displayUnavailable:
            return .displayUnavailable
        case .cropFailed:
            return .cropFailed
        case .copyOnly, .saveAndCopy, .copyPixelValues:
            return nil
        }
    }
}
private final class ScreenshotSelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
