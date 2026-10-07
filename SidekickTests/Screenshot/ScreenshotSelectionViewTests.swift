import AppKit
import ImageIO
import XCTest

@MainActor
final class ScreenshotSelectionViewTests: XCTestCase {
    func testCKeyCopiesTheFrozenDisplayWhenNoAreaIsDrawn() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let view = makeView(image: image)
        let (choices, continuation) = AsyncStream<ScreenshotSelectionChoice>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        view.choiceContinuation = continuation
        defer {
            continuation.finish()
            view.choiceContinuation = nil
        }

        view.keyDown(with: try keyEvent(keyCode: 8, character: "c"))

        var iterator = choices.makeAsyncIterator()
        guard case let .copyOnly(selectedImage)? = await iterator.next() else {
            return XCTFail("C must copy the frozen display without saving")
        }
        XCTAssertEqual(selectedImage.width, image.width)
        XCTAssertEqual(selectedImage.height, image.height)
    }

    func testMouseUpLeavesDrawnAreaForCopyOnlyC() async throws {
        let data = try pngData(width: 400, height: 400)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let view = makeView(image: image)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let (choices, continuation) = AsyncStream<ScreenshotSelectionChoice>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        view.choiceContinuation = continuation
        defer {
            continuation.finish()
            view.choiceContinuation = nil
        }

        view.mouseDown(with: try mouseEvent(.leftMouseDown, at: NSPoint(x: 50, y: 200), window: window))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: 150, y: 300), window: window))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, at: NSPoint(x: 150, y: 300), window: window))
        view.keyDown(with: try keyEvent(keyCode: 8, character: "c"))

        var iterator = choices.makeAsyncIterator()
        guard case let .copyOnly(selectedImage)? = await iterator.next() else {
            return XCTFail("Drawing a region must leave it available for C copy-only")
        }
        XCTAssertEqual(selectedImage.width, 100)
        XCTAssertEqual(selectedImage.height, 100)
    }

    func testFCompletesFullDisplayAndSaveButtonIsVisible() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let view = makeView(image: image)
        let saveButton = try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Save & Copy" })
        XCTAssertTrue(saveButton.target === view)

        let (choices, continuation) = AsyncStream<ScreenshotSelectionChoice>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        view.choiceContinuation = continuation
        defer {
            continuation.finish()
            view.choiceContinuation = nil
        }
        view.keyDown(with: try keyEvent(keyCode: 3, character: "f"))

        var iterator = choices.makeAsyncIterator()
        guard case let .selected(selectedImage)? = await iterator.next() else {
            return XCTFail("F must select the full display")
        }
        XCTAssertEqual(selectedImage.width, image.width)
        XCTAssertEqual(selectedImage.height, image.height)
    }

    func testSaveButtonEmitsExplicitSaveAndCopyChoice() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let view = makeView(image: image)
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Save & Copy" })
        XCTAssertTrue(button.target === view)
        XCTAssertEqual(button.action, #selector(ScreenshotSelectionView.saveAndCopySelection))
        let (choices, continuation) = AsyncStream<ScreenshotSelectionChoice>.makeStream(
            bufferingPolicy: .bufferingOldest(1)
        )
        view.choiceContinuation = continuation
        defer {
            continuation.finish()
            view.choiceContinuation = nil
        }

        view.saveAndCopySelection()

        var iterator = choices.makeAsyncIterator()
        guard case let .saveAndCopy(selectedImage)? = await iterator.next() else {
            return XCTFail("Save & Copy button must force a save result")
        }
        XCTAssertEqual(selectedImage.width, image.width)
        XCTAssertEqual(selectedImage.height, image.height)
    }
    private func makeView(image: CGImage) -> ScreenshotSelectionView {
        ScreenshotSelectionView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400),
            image: image,
            windowTargets: nil
        )
    }

    private func keyEvent(
        keyCode: UInt16,
        character: String,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }
}
