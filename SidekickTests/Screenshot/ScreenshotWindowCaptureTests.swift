import AppKit
import XCTest

extension ScreenshotCaptureIntegrationTests {
    func testScreenshotWindowTargetsMapBoundsAndRejectOcclusionOrUnavailableWindows() throws {
        let displayBounds = CGRect(x: 100, y: 50, width: 800, height: 600)
        let snapshots = [
            ScreenshotWindowSnapshot(
                windowID: 7,
                bounds: CGRect(x: 220, y: 110, width: 100, height: 100),
                layer: 20,
                alpha: 1
            ),
            ScreenshotWindowSnapshot(
                windowID: 1,
                bounds: CGRect(x: 200, y: 100, width: 200, height: 100),
                layer: 0,
                alpha: 1
            ),
            ScreenshotWindowSnapshot(
                windowID: 5,
                bounds: CGRect(x: 400, y: 100, width: 100, height: 100),
                layer: 0,
                alpha: 1
            ),
            ScreenshotWindowSnapshot(
                windowID: 6,
                bounds: CGRect(x: 200, y: 100, width: 300, height: 100),
                layer: 0,
                alpha: 1
            ),
            ScreenshotWindowSnapshot(
                windowID: 2,
                bounds: CGRect(x: 150, y: 80, width: 300, height: 200),
                layer: 0,
                alpha: 1
            ),
            ScreenshotWindowSnapshot(
                windowID: 3,
                bounds: CGRect(x: 700, y: 200, width: 100, height: 100),
                layer: 0,
                alpha: 1
            ),
            ScreenshotWindowSnapshot(
                windowID: 4,
                bounds: CGRect(x: 50, y: 50, width: 100, height: 100),
                layer: 0,
                alpha: 1
            )
        ]

        let targets = try XCTUnwrap(ScreenshotWindowTargeting.targets(
            from: snapshots,
            displayBounds: displayBounds,
            screenSize: CGSize(width: 1_600, height: 1_200)
        ))

        assertScreenshotWindowTargeting(targets)
    }
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
            select: { _, _, _, _ in .cancelled },
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
    func testCaptureFailureDoesNotSelectOrMutateClipboard() async {
        let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "preserve")
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            capture: { _ in throw ActiveDisplayScreenshotError.activeDisplayUnavailable },
            select: { _, _, _, _ in
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
    func testScreenRecordingPermissionDenialProvidesActionableMessage() {
        XCTAssertEqual(
            ScreenshotCaptureFailurePresentation.permissionAwareCaptureMessage(screenRecordingAllowed: false),
            "Allow Screen Recording for Sidekick in System Settings, then retry."
        )
        XCTAssertEqual(
            ScreenshotCaptureFailurePresentation.permissionAwareCaptureMessage(screenRecordingAllowed: true),
            "Couldn’t capture the display."
        )
        XCTAssertEqual(
            ScreenshotCaptureFailurePresentation.permissionAwareCaptureMessage(
                screenRecordingAllowed: true,
                isWindowCapture: true
            ),
            "Couldn’t capture the selected window; choose another window or region."
        )
    }
    func testSelectedWindowCaptureUsesCursorPolicyAndReportsFailure() async throws {
        let suiteName = "ScreenshotWindowCaptureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.screenshotCursorIncludedByDefault = true
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(
            from: try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        )
        let target = ScreenshotWindowTarget(
            windowID: 44,
            bounds: CGRect(x: 20, y: 30, width: 40, height: 50),
            layer: 0
        )
        let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "preserve")
        var displayCursorSettings: [Bool] = []
        var windowCursorSettings: [Bool] = []
        var failures: [ScreenshotCaptureController.Failure] = []
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            settings: settings,
            capture: { showsCursor in
                displayCursorSettings.append(showsCursor)
                return screenshot
            },
            captureWindow: { selected, showsCursor in
                XCTAssertEqual(selected.windowID, target.windowID)
                windowCursorSettings.append(showsCursor)
                throw ActiveDisplayScreenshotError.windowUnavailable
            },
            select: { _, showsCursor, windowCapture, _ in
                do {
                    return .selected(try await windowCapture(target, showsCursor))
                } catch {
                    return .windowCaptureFailed
                }
            },
            onCopied: { XCTFail("Failed window capture must not copy") },
            onFailure: { failures.append($0) }
        )

        await controller.copyActiveDisplayToClipboard(cursorOverride: false)
        await controller.copyActiveDisplayToClipboard()

        XCTAssertEqual(displayCursorSettings, [false, true])
        XCTAssertEqual(windowCursorSettings, [false, true])
        XCTAssertEqual(failures, [.windowCapture, .windowCapture])
        XCTAssertEqual(pasteboard.value, "preserve")
        XCTAssertEqual(pasteboard.writeCount, 0)
    }
    func testRealCaptureIncludesVisibleWindowBoundsAndCursorOption() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is required for this integration test")
        }
        let pointerLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointerLocation) }) else {
            throw XCTSkip("No display containing the pointer is available")
        }

        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let (window, coveringWindow) = makeScreenshotCaptureWindows(on: screen)
        window.makeKeyAndOrderFront(nil)
        coveringWindow.makeKeyAndOrderFront(nil)
        defer {
            coveringWindow.orderOut(nil)
            window.orderOut(nil)
        }

        let withoutCursor = try await ActiveDisplayScreenshotCapture.capture(showsCursor: false)
        let withCursor = try await ActiveDisplayScreenshotCapture.capture(showsCursor: true)
        let windowTarget = try XCTUnwrap(withoutCursor.windowTargets?.first {
            $0.windowID == CGWindowID(window.windowNumber)
        })

        XCTAssertTrue(windowTarget.isCapturable)
        XCTAssertEqual(windowTarget.bounds.minX, window.frame.minX - screen.frame.minX, accuracy: 1)
        XCTAssertEqual(windowTarget.bounds.minY, window.frame.minY - screen.frame.minY, accuracy: 1)
        XCTAssertEqual(windowTarget.bounds.width, window.frame.width, accuracy: 1)
        XCTAssertEqual(windowTarget.bounds.height, window.frame.height, accuracy: 1)
        XCTAssertEqual(withoutCursor.displayID, withCursor.displayID)
        let exposedPoint = CGPoint(
            x: windowTarget.bounds.minX + windowTarget.bounds.width * 0.1,
            y: windowTarget.bounds.midY
        )
        XCTAssertEqual(
            ScreenshotWindowTargeting.selection(at: exposedPoint, from: withoutCursor.windowTargets ?? []),
            .selected(windowTarget)
        )
        let selectedWindowImage = try await ActiveDisplayScreenshotCapture.captureWindow(
            windowTarget,
            showsCursor: false
        )
        XCTAssertGreaterThan(selectedWindowImage.width, 0)
        XCTAssertGreaterThan(selectedWindowImage.height, 0)
        XCTAssertLessThan(selectedWindowImage.width, withoutCursor.image.width)
        XCTAssertLessThan(selectedWindowImage.height, withoutCursor.image.height)
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
            (.cropFailed, .selectionCropFailed),
            (.windowUnavailable, .selectionWindowUnavailable)
        ]

        for (selectionResult, expectedFailure) in failures {
            let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "preserve")
            var failure: ScreenshotCaptureController.Failure?
            let controller = ScreenshotCaptureController(
                pasteboard: pasteboard,
                capture: { _ in screenshot },
                select: { _, _, _, _ in selectionResult },
                onCopied: { XCTFail("Selection failure must not be reported as copied") },
                onFailure: { failure = $0 }
            )

            await controller.copyActiveDisplayToClipboard()

            XCTAssertEqual(failure, expectedFailure)
            XCTAssertEqual(pasteboard.value, "preserve")
            XCTAssertEqual(pasteboard.writeCount, 0)
        }
    }
    func testTerminationDuringWindowCaptureDoesNotWriteLateImage() async throws {
        let pasteboard = ScreenshotCaptureTestSupport.ScreenshotRacePasteboard(value: "preserve")
        let gate = ScreenshotCaptureGate()
        let screenshot = ScreenshotCaptureTestSupport.capturedScreenshot(
            from: try XCTUnwrap(ScreenshotCaptureTestSupport.makePixelImage())
        )
        let target = ScreenshotWindowTarget(
            windowID: 91,
            bounds: CGRect(x: 20, y: 30, width: 40, height: 50),
            layer: 0
        )
        var copied = false
        var failure: ScreenshotCaptureController.Failure?
        let controller = ScreenshotCaptureController(
            pasteboard: pasteboard,
            capture: { _ in screenshot },
            captureWindow: { _, _ in try await gate.capture().image },
            select: { _, showsCursor, windowCapture, _ in
                do {
                    return .selected(try await windowCapture(target, showsCursor))
                } catch {
                    return .windowCaptureFailed
                }
            },
            onCopied: { copied = true },
            onFailure: { failure = $0 }
        )
        let operation = Task { @MainActor in
            await controller.copyActiveDisplayToClipboard()
        }

        await gate.waitUntilStarted()
        controller.terminate()
        gate.resume(with: screenshot)
        await operation.value

        XCTAssertEqual(pasteboard.value, "preserve")
        XCTAssertEqual(pasteboard.writeCount, 0)
        XCTAssertFalse(copied)
        XCTAssertNil(failure)
    }
}
private func assertScreenshotWindowTargeting(_ targets: [ScreenshotWindowTarget]) {
    XCTAssertEqual(targets.map(\.windowID), [7, 1, 5, 6, 2, 3, 4])
    XCTAssertEqual(targets[0].layer, 20)
    XCTAssertEqual(targets[1].bounds, CGRect(x: 200, y: 900, width: 400, height: 200))
    XCTAssertFalse(targets[5].isCapturable)
    XCTAssertEqual(targets[6].bounds, CGRect(x: 0, y: 1_000, width: 100, height: 200))
    XCTAssertEqual(
        ScreenshotWindowTargeting.selection(at: CGPoint(x: 300, y: 950), from: targets),
        .unavailable(targets[0])
    )
    XCTAssertEqual(
        ScreenshotWindowTargeting.selection(at: CGPoint(x: 650, y: 800), from: targets),
        .unavailable(targets[4])
    )
    XCTAssertEqual(
        ScreenshotWindowTargeting.selection(at: CGPoint(x: 1_300, y: 800), from: targets),
        .unavailable(targets[5])
    )
    XCTAssertEqual(
        ScreenshotWindowTargeting.selection(at: CGPoint(x: 900, y: 400), from: targets),
        .none
    )
}

@MainActor
private func makeScreenshotCaptureWindows(
    on screen: NSScreen
) -> (window: NSWindow, coveringWindow: NSWindow) {
    let windowFrame = CGRect(
        x: screen.frame.minX + screen.frame.width * 0.2,
        y: screen.frame.minY + screen.frame.height * 0.25,
        width: screen.frame.width * 0.4,
        height: screen.frame.height * 0.5
    )
    let window = NSWindow(
        contentRect: windowFrame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false,
        screen: screen
    )
    window.isReleasedWhenClosed = false
    window.level = .normal
    window.backgroundColor = NSColor(red: 0.17, green: 0.23, blue: 0.31, alpha: 1)
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    let coveringFrame = CGRect(
        x: windowFrame.minX + windowFrame.width * 0.2,
        y: windowFrame.minY,
        width: windowFrame.width * 0.8,
        height: windowFrame.height
    )
    let coveringWindow = NSWindow(
        contentRect: coveringFrame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false,
        screen: screen
    )
    coveringWindow.isReleasedWhenClosed = false
    coveringWindow.level = .normal
    coveringWindow.backgroundColor = NSColor(red: 0.42, green: 0.19, blue: 0.21, alpha: 1)
    coveringWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    return (window, coveringWindow)

}
