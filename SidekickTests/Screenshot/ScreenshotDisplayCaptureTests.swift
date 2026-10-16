import AppKit
import XCTest

extension ScreenshotCaptureIntegrationTests {
    func testControllerUsesSavedCursorDefaultAndPerCaptureOverride() async throws {
        let suiteName = "ScreenshotCursorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.screenshotCursorIncludedByDefault = true
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(
            from: try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        )
        let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "preserve")
        var capturedCursorSettings: [Bool] = []
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: settings,
            capture: { showsCursor in
                capturedCursorSettings.append(showsCursor)
                return screenshot
            },
            select: { _, _ in .cancelled },
            onCopied: {},
            onFailure: { XCTFail("Selection cancellation should not fail: \($0)") }
        )

        await controller.copyActiveDisplayToClipboard()
        await controller.copyActiveDisplayToClipboard(cursorOverride: false)
        await controller.copyActiveDisplayToClipboard(cursorOverride: true)

        XCTAssertEqual(capturedCursorSettings, [true, false, true])
        XCTAssertEqual(pasteboard.value, "preserve")
        XCTAssertEqual(pasteboard.writeCount, 0)
    }
    func testRequestStatePreservesCursorOverrideForWindowCapture() {
        let request = ScreenshotCaptureController.RequestState(
            id: UUID(),
            expectedChangeCount: 0,
            delivery: .copy,
            startedAt: Date(),
            saveDirectory: URL(fileURLWithPath: "captures"),
            filenameTemplate: "capture",
            screenshotCopyAsOutputFormat: false,
            imageFormat: .webP,
            showsCursor: false
        )

        XCTAssertFalse(request.showsCursor)
    }
    func testCaptureFailureDoesNotSelectOrMutateClipboard() async {
        let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "preserve")
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            capture: { _ in throw ActiveDisplayScreenshotError.activeDisplayUnavailable },
            select: { _, _ in
                XCTFail("A failed capture must not enter selection")
                return .cancelled
            },
            onCopied: { XCTFail("A failed capture must not be reported as copied") },
            onFailure: { failure = $0 }
        )

        await controller.copyActiveDisplayToClipboard()

        XCTAssertEqual(failure, .capture)
        XCTAssertEqual(pasteboard.value, "preserve")
        XCTAssertEqual(pasteboard.writeCount, 0)
    }
    func testRealDisplayCaptureIncludesCursorWhenRequested() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is required for this integration test")
        }
        let pointerLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointerLocation) }) else {
            throw XCTSkip("No display containing the pointer is available")
        }

        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let withoutCursor = try await ActiveDisplayScreenshotCapture.capture(showsCursor: false)
        let withCursor = try await ActiveDisplayScreenshotCapture.capture(showsCursor: true)

        XCTAssertEqual(withoutCursor.displayID, withCursor.displayID)
        XCTAssertEqual(withoutCursor.screenFrame, screen.frame)
        XCTAssertGreaterThan(withoutCursor.image.width, 0)
        XCTAssertGreaterThan(withoutCursor.image.height, 0)
        XCTAssertGreaterThan(
            differingPixelCount(
                withoutCursor.image,
                withCursor.image,
                around: pointerLocation,
                screenFrame: withoutCursor.screenFrame
            ),
            0,
            "Cursor-enabled capture should include pointer pixels"
        )
    }
    func testSelectionFailuresReportWithoutClipboardMutation() async throws {
        let image = try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(from: image)
        let failures: [(ScreenshotSelectionResult, ScreenshotCaptureController.Failure)] = [
            (.displayUnavailable, .selectionDisplayUnavailable),
            (.cropFailed, .selectionCropFailed)
        ]

        for (selectionResult, expectedFailure) in failures {
            let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "preserve")
            var failure: ScreenshotCaptureController.Failure?
            let controller = ScreenshotCaptureController(
                pasteboard: pasteboard,
                capture: { _ in screenshot },
                select: { _, _ in selectionResult },
                onCopied: { XCTFail("Selection failure must not be reported as copied") },
                onFailure: { failure = $0 }
            )

            await controller.copyActiveDisplayToClipboard()

            XCTAssertEqual(failure, expectedFailure)
            XCTAssertEqual(pasteboard.value, "preserve")
            XCTAssertEqual(pasteboard.writeCount, 0)
        }
    }
}

extension ScreenshotCaptureIntegrationTests {
    func testOverlayWindowSelectionKeepsVisibleModeDuringTwoEmptyInventoryRetries() async throws {
        let application = NSApplication.shared
        guard !NSScreen.screens.isEmpty else {
            throw XCTSkip("A display is required for the window-capture overlay")
        }
        let secondAttemptStarted = expectation(description: "Second window inventory attempt started")
        let visibleSelectionPanels = {
            application.windows.filter {
                $0.isVisible &&
                    $0.level == .screenSaver &&
                    $0.styleMask.contains(.nonactivatingPanel)
            }.count
        }
        let initialPanelCount = visibleSelectionPanels()
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(
            from: try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        )
        var attemptCount = 0
        var secondAttemptContinuation: CheckedContinuation<Void, Never>?
        var failures: [ScreenshotCaptureController.Failure] = []
        let controller = ScreenshotCaptureController(
            pasteboard: ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "preserve"),
            capture: { _ in screenshot },
            select: { _, _ in .windowCapture },
            windowInventory: {
                attemptCount += 1
                if attemptCount == 2 {
                    await withCheckedContinuation { continuation in
                        secondAttemptContinuation = continuation
                        secondAttemptStarted.fulfill()
                    }
                }
                return WindowScreenshotInventory()
            },
            hasWindowCaptureAccess: { true },
            onCopied: { XCTFail("An empty inventory must not report a copied window") },
            onFailure: { failures.append($0) }
        )
        let operation = Task { @MainActor in
            await controller.copyActiveDisplayToClipboard()
        }

        await fulfillment(of: [secondAttemptStarted], timeout: 5)
        XCTAssertGreaterThan(visibleSelectionPanels(), initialPanelCount)
        XCTAssertNotNil(controller.activeRequestID)
        XCTAssertTrue(failures.isEmpty)

        secondAttemptContinuation?.resume()
        await operation.value

        XCTAssertEqual(attemptCount, 3)
        XCTAssertEqual(failures, [.noCapturableWindow])
        XCTAssertNil(controller.activeRequestID)
        XCTAssertEqual(visibleSelectionPanels(), initialPanelCount)
    }
}
