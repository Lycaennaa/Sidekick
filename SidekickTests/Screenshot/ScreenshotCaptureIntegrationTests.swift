import AppKit
import XCTest

@MainActor
final class ScreenshotCaptureIntegrationTests: XCTestCase {
    func testDefaultScreenshotCommandUsesRealDisplayAndPasteboard() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is required for this integration test")
        }
        guard !NSScreen.screens.isEmpty else {
            throw XCTSkip("No active display is available")
        }

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ScreenshotCapture-\(UUID().uuidString)"))
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }

        var copied = false
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            onCopied: { copied = true },
            onFailure: { failure = $0 }
        )
        let operation = Task { @MainActor in
            await controller.copyActiveDisplayToClipboard()
        }
        defer {
            operation.cancel()
            controller.terminate()
        }
        guard let window = await waitForSelectionWindow(timeout: 30) else {
            XCTFail("Default screenshot command did not present its selection overlay")
            return
        }

        let wasKeyWindow = window.isKeyWindow
        let returnEvent = try XCTUnwrap(makeKeyEvent(36, characters: "\r", in: window))
        window.sendEvent(returnEvent)
        await operation.value

        XCTAssertTrue(wasKeyWindow, "Screenshot selection window should become key")
        XCTAssertTrue(copied)
        XCTAssertNil(failure)
        XCTAssertNotNil(pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png))
    }

    func testSelectionCancellationPreservesClipboard() async throws {
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(
            from: try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        )
        let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "prior clipboard value")
        var copied = false
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            capture: { _ in screenshot },
            select: { _, _, _, _ in .cancelled },
            onCopied: { copied = true },
            onFailure: { failure = $0 }
        )

        await controller.copyActiveDisplayToClipboard()

        XCTAssertEqual(pasteboard.value, "prior clipboard value")
        XCTAssertEqual(pasteboard.writeCount, 0)
        XCTAssertFalse(copied)
        XCTAssertNil(failure)
    }

    func testScreenshotWritesPNGToRealPasteboard() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let target = ScreenshotWindowTarget(
            windowID: 77,
            bounds: CGRect(x: 20, y: 30, width: 40, height: 50),
            layer: 0
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ScreenshotWriter-\(UUID().uuidString)"))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("prior clipboard value", forType: .string))
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        let metadataRegistry = ScreenshotClipboardMetadataRegistry()
        var copied = false
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            capture: { _ in ScreenshotCaptureTestSupport.capturedScreenshot(from: image) },
            captureWindow: { selected, _ in
                XCTAssertEqual(selected.windowID, target.windowID)
                return image
            },
            select: { _, showsCursor, windowCapture, _ in
                do {
                    return .selected(try await windowCapture(target, showsCursor))
                } catch {
                    return .windowCaptureFailed
                }
            },
            metadataRegistry: metadataRegistry,
            onCopied: { copied = true },
            onFailure: { failure = $0 }
        )

        await controller.copyActiveDisplayToClipboard()

        XCTAssertTrue(copied)
        XCTAssertNil(failure)
        let png = try XCTUnwrap(pasteboard.data(forType: .png))
        XCTAssertTrue(png.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let screenshotDynamicRange = metadataRegistry.dynamicRange(forChangeCount: pasteboard.changeCount)
        XCTAssertEqual(screenshotDynamicRange, .sdr)
        XCTAssertNil(metadataRegistry.dynamicRange(forChangeCount: pasteboard.changeCount + 1))
        let analysis = await ClipboardPayloadClassifier.analyze(
            items: pasteboard.pasteboardItems ?? [],
            generation: 12,
            payloadReader: InlinePasteboardPayloadReader(),
            screenshotDynamicRange: screenshotDynamicRange
        )
        let toast = ClipboardPayloadPresentation.toastModel(from: analysis.classification)
        XCTAssertEqual(toast.summary, "Copied image • SDR (HDR not preserved)")
    }

    func testLateScreenshotDoesNotOverwriteClipboardChangedDuringCapture() async throws {
        let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "initial")
        let gate = ScreenshotCaptureGate()
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            capture: { _ in try await gate.capture() },
            select: { screenshot, _, _, _ in .selected(screenshot.image) },
            onCopied: { XCTFail("Stale screenshot replaced the clipboard") },
            onFailure: { failure = $0 }
        )
        let operation = Task { @MainActor in
            await controller.copyActiveDisplayToClipboard()
        }
        await gate.waitUntilStarted()
        pasteboard.replaceContents("newer")
        gate.resume(with: ScreenshotCaptureTestSupport.capturedScreenshot(
            from: try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        ))
        await operation.value

        XCTAssertEqual(pasteboard.value, "newer")
        XCTAssertEqual(pasteboard.writeCount, 0)
        XCTAssertEqual(failure, .clipboardChanged)
    }

    func testTerminationDuringCaptureDoesNotWriteLateImage() async throws {
        let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "preserve")
        let gate = ScreenshotCaptureGate()
        var copied = false
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            capture: { _ in try await gate.capture() },
            select: { screenshot, _, _, _ in .selected(screenshot.image) },
            onCopied: { copied = true },
            onFailure: { failure = $0 }
        )
        let operation = Task { @MainActor in
            await controller.copyActiveDisplayToClipboard()
        }

        await gate.waitUntilStarted()
        controller.terminate()
        gate.resume(with: ScreenshotCaptureTestSupport.capturedScreenshot(
            from: try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        ))
        await operation.value

        XCTAssertEqual(pasteboard.value, "preserve")
        XCTAssertEqual(pasteboard.writeCount, 0)
        XCTAssertFalse(copied)
        XCTAssertNil(failure)
    }

    func testReplacementChecksScreenshotOwnershipBeforeMutation() async {
        let pasteboard = PasteboardSnapshotFakePasteboard(
            items: [makePasteboardSnapshotItem(text: "preserve")]
        )
        let originalChangeCount = pasteboard.changeCount
        let captureResult = await PasteboardSnapshot.capture(
            from: pasteboard,
            expectedChangeCount: originalChangeCount,
            limits: PasteboardSnapshot.Limits(
                maximumBytes: 1_024,
                maximumItems: 4,
                maximumTypesPerItem: 4
            ),
            payloadReader: InlinePasteboardPayloadReader()
        )
        guard case let .captured(snapshot) = captureResult else {
            return XCTFail("Expected a complete source clipboard snapshot")
        }

        let gate = ScreenshotTransactionOwnershipGate()
        let replacement = makePasteboardSnapshotItem(text: "screenshot")
        let operation = Task { @MainActor in
            await snapshot.replace(
                pasteboard: pasteboard,
                expectedChangeCount: originalChangeCount,
                with: [replacement],
                payloadReader: InlinePasteboardPayloadReader(),
                isStillOwned: { await gate.verifyAndWait() }
            )
        }

        await gate.waitUntilVerificationStarts()
        gate.revokeAndResume()
        let result = await operation.value

        guard case .stale = result else {
            return XCTFail("Ownership loss must stop the clipboard replacement before mutation")
        }
        XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "preserve")
    }
    func testTerminationWaitsForRollbackAfterPasteboardMutationStarts() async throws {
        let pasteboard = PasteboardSnapshotFakePasteboard(
            items: [makePasteboardSnapshotItem(text: "original")]
        )
        let reader = ScreenshotPostWritePayloadReader()
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            capture: { _ in ScreenshotCaptureTestSupport.capturedScreenshot(from: image) },
            select: { screenshot, _, _, _ in .selected(screenshot.image) },
            metadataRegistry: ScreenshotClipboardMetadataRegistry(),
            payloadReader: reader,
            onCopied: { XCTFail("Cancelled screenshot was reported as copied") },
            onFailure: { _ in XCTFail("Cancelled screenshot should not report a stale failure") }
        )
        let operation = Task { @MainActor in
            await controller.copyActiveDisplayToClipboard()
        }

        await reader.waitUntilPNGRead()
        XCTAssertTrue(controller.hasPendingPasteboardMutation)
        XCTAssertNotNil(pasteboard.data(forType: .png))
        controller.terminate()
        operation.cancel()
        reader.resumePNGRead()
        await operation.value

        XCTAssertFalse(controller.hasPendingPasteboardMutation)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func differingPixelCount(
        _ lhs: CGImage,
        _ rhs: CGImage,
        around point: NSPoint,
        screenFrame: CGRect
    ) -> Int {
        guard lhs.width == rhs.width, lhs.height == rhs.height,
              lhs.bitsPerPixel == rhs.bitsPerPixel,
              lhs.width > 0, lhs.height > 0,
              screenFrame.width > 0, screenFrame.height > 0,
              let lhsData = lhs.dataProvider?.data as Data?,
              let rhsData = rhs.dataProvider?.data as Data? else {
            return 0
        }
        let bytesPerPixel = lhs.bitsPerPixel / 8
        guard bytesPerPixel > 0 else { return 0 }
        let centerX = Int((point.x - screenFrame.minX) * CGFloat(lhs.width) / screenFrame.width)
        let centerY = Int((screenFrame.maxY - point.y) * CGFloat(lhs.height) / screenFrame.height)
        let minX = max(0, centerX - 48)
        let maxX = min(lhs.width, centerX + 48)
        let minY = max(0, centerY - 48)
        let maxY = min(lhs.height, centerY + 48)
        guard minX < maxX, minY < maxY else { return 0 }

        return lhsData.withUnsafeBytes { lhsBytes in
            rhsData.withUnsafeBytes { rhsBytes in
                var differences = 0
                for pixelRow in minY..<maxY {
                    for pixelColumn in minX..<maxX {
                        let lhsOffset = pixelRow * lhs.bytesPerRow + pixelColumn * bytesPerPixel
                        let rhsOffset = pixelRow * rhs.bytesPerRow + pixelColumn * bytesPerPixel
                        if (0..<bytesPerPixel).contains(where: {
                            lhsBytes[lhsOffset + $0] != rhsBytes[rhsOffset + $0]
                        }) {
                            differences += 1
                        }
                    }
                }
                return differences
            }
        }
    }
    private func waitForSelectionWindow(timeout: TimeInterval) async -> NSWindow? {
        let deadline = Date().addingTimeInterval(timeout)
        var selectionWindow: NSWindow?
        while selectionWindow == nil, Date() < deadline {
            let keyWindowBecameKey = expectation(
                forNotification: NSWindow.didBecomeKeyNotification,
                object: nil
            )
            selectionWindow = NSApp.windows.first(where: {
                $0.styleMask == .borderless && $0.level == .screenSaver
            })
            if selectionWindow == nil {
                await fulfillment(of: [keyWindowBecameKey], timeout: deadline.timeIntervalSinceNow)
            }
        }
        return selectionWindow
    }

    private func makeKeyEvent(_ keyCode: UInt16, characters: String, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
    }

}
extension ScreenshotCaptureIntegrationTests {
    @MainActor
    private final class ScreenshotTransactionOwnershipGate {
        private var isOwned = true
        private var verificationStarted = false
        private var verificationWaiters: [CheckedContinuation<Void, Never>] = []
        private var verificationContinuation: CheckedContinuation<Void, Never>?

        func verifyAndWait() async -> Bool {
            await withCheckedContinuation { continuation in
                verificationContinuation = continuation
                verificationStarted = true
                let waiters = verificationWaiters
                verificationWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
            return isOwned
        }

        func waitUntilVerificationStarts() async {
            guard !verificationStarted else { return }
            await withCheckedContinuation { continuation in
                verificationWaiters.append(continuation)
            }
        }

        func revokeAndResume() {
            isOwned = false
            verificationContinuation?.resume()
            verificationContinuation = nil
        }
    }
    @MainActor
    private final class ScreenshotPostWritePayloadReader: PasteboardPayloadReading {
        private let inlineReader = InlinePasteboardPayloadReader()
        private var hasStartedPNGRead = false
        private var pngReadWaiters: [CheckedContinuation<Void, Never>] = []
        private var pngReadContinuation: CheckedContinuation<Void, Never>?

        func readData(
            from item: NSPasteboardItem,
            forType type: NSPasteboard.PasteboardType,
            maximumBytes: Int
        ) async -> PasteboardPayloadReader.Result {
            if type == .png, !hasStartedPNGRead {
                await withCheckedContinuation { continuation in
                    pngReadContinuation = continuation
                    hasStartedPNGRead = true
                    let waiters = pngReadWaiters
                    pngReadWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                }
            }
            return await inlineReader.readData(from: item, forType: type, maximumBytes: maximumBytes)
        }

        func waitUntilPNGRead() async {
            guard !hasStartedPNGRead else { return }
            await withCheckedContinuation { continuation in
                pngReadWaiters.append(continuation)
            }
        }

        func resumePNGRead() {
            pngReadContinuation?.resume()
            pngReadContinuation = nil
        }
    }

    @MainActor
    final class ScreenshotCaptureGate {
        private var hasStarted = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var imageContinuation: CheckedContinuation<CGImage, Error>?

        func capture() async throws -> CapturedDisplayScreenshot {
            let image = try await withCheckedThrowingContinuation { continuation in
                imageContinuation = continuation
                hasStarted = true
                let waiters = startWaiters
                startWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
            return CapturedDisplayScreenshot(image: image, displayID: 0, screenFrame: .zero)
        }

        func waitUntilStarted() async {
            guard !hasStarted else { return }
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }

        func resume(with screenshot: CapturedDisplayScreenshot) {
            imageContinuation?.resume(returning: screenshot.image)
            imageContinuation = nil
        }
    }
}
