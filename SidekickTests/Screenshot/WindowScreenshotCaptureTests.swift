import AppKit
import XCTest

@MainActor
final class WindowScreenshotCaptureTests: XCTestCase {
    func testDefaultWindowCaptureUsesRealScreenCaptureKitWindow() async throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No active display is available")
        }

        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("Screen Recording permission is required for this integration test")
        }

        let title = "Sidekick Window Capture Integration"
        let window = NSWindow(
            contentRect: CGRect(x: screen.frame.minX + 40, y: screen.frame.minY + 40, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = title
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.displayIfNeeded()
        defer { window.close() }

        let inventory = try await WindowScreenshotCapture.windows()
        let selectedWindow = try XCTUnwrap(inventory.windows.first(where: { $0.title == title }))

        let image = try await WindowScreenshotCapture.capture(
            windowID: selectedWindow.id,
            from: inventory,
            showsCursor: false
        )

        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
        window.close()
        do {
            _ = try await WindowScreenshotCapture.capture(
                windowID: selectedWindow.id,
                from: inventory,
                showsCursor: false
            )
            XCTFail("A closed window must not be captured from the stale enumeration")
        } catch {
            // ScreenCaptureKit reports that the previously enumerated window is unavailable.
        }

    }

    func testCandidatePolicyExcludesSystemUIAndOwnFullscreenCapture() {
        func candidate(
            bundleID: String? = "com.example.app",
            appName: String = "Example",
            hasOwningApplication: Bool = true,
            windowLayer: Int = 0,
            isOwnAppWindow: Bool = false
        ) -> ScreenshotWindowCandidate {
            ScreenshotWindowCandidate(
                frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                isOnScreen: true,
                title: "Example Window",
                appName: appName,
                bundleID: bundleID,
                hasOwningApplication: hasOwningApplication,
                windowLayer: windowLayer,
                isOwnAppWindow: isOwnAppWindow
            )
        }

        XCTAssertTrue(candidate().isSelectable)
        XCTAssertTrue(candidate(isOwnAppWindow: true).isSelectable)
        XCTAssertFalse(candidate(
            windowLayer: Int(CGWindowLevelForKey(.screenSaverWindow)),
            isOwnAppWindow: true
        ).isSelectable)
        XCTAssertFalse(
            candidate(bundleID: "com.apple.notificationcenterui", appName: "Notification Center").isSelectable
        )
        XCTAssertFalse(candidate(
            bundleID: nil,
            appName: "",
            hasOwningApplication: false,
            windowLayer: Int(CGWindowLevelForKey(.mainMenuWindow))
        ).isSelectable)
        XCTAssertFalse(
            candidate(
                bundleID: "com.apple.systemuiserver",
                appName: "SystemUIServer",
                windowLayer: Int(CGWindowLevelForKey(.mainMenuWindow))
            ).isSelectable
        )
    }

    func testVisibilityExcludesFullyCoveredWindowsAndSystemOverlays() {
        let windows = [
            ScreenshotWindowOcclusion(
                id: 1,
                frame: CGRect(x: 0, y: 0, width: 50, height: 100),
                alpha: 1,
                bundleIdentifier: "com.example.front"
            ),
            ScreenshotWindowOcclusion(
                id: 2,
                frame: CGRect(x: 50, y: 0, width: 50, height: 100),
                alpha: 1,
                bundleIdentifier: "com.example.front"
            ),
            ScreenshotWindowOcclusion(
                id: 3,
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                alpha: 1,
                bundleIdentifier: "com.apple.dock"
            ),
            ScreenshotWindowOcclusion(
                id: 4,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                alpha: 1,
                bundleIdentifier: "com.example.rear"
            )
        ]

        XCTAssertEqual(
            ScreenshotWindowVisibility.visibleWindowIDs(
                frontToBack: windows,
                selectableIDs: [1, 2, 4]
            ),
            [1, 2]
        )
    }
    func testVisibilityKeepsUnoccludedWindowsWhenFramesDoNotOverlap() {
        let occluderFrame = CGRect(x: 0, y: 0, width: 50, height: 100)
        let windowFrame = CGRect(x: 200, y: 0, width: 100, height: 100)
        let windows = [
            ScreenshotWindowOcclusion(
                id: 1,
                frame: occluderFrame,
                alpha: 1,
                bundleIdentifier: "com.example.front"
            ),
            ScreenshotWindowOcclusion(
                id: 2,
                frame: windowFrame,
                alpha: 1,
                bundleIdentifier: "com.example.rear"
            )
        ]

        XCTAssertEqual(
            ScreenshotWindowVisibility.visibleRegionsByWindowID(
                frontToBack: windows,
                selectableIDs: [2]
            ),
            [2: [windowFrame]]
        )
    }

    func testVisibilityKeepsPartiallyVisibleWindows() {
        let windows = [
            ScreenshotWindowOcclusion(
                id: 1,
                frame: CGRect(x: 0, y: 0, width: 25, height: 100),
                alpha: 1,
                bundleIdentifier: "com.example.front"
            ),
            ScreenshotWindowOcclusion(
                id: 2,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                alpha: 1,
                bundleIdentifier: "com.example.rear"
            )
        ]

        XCTAssertEqual(
            ScreenshotWindowVisibility.visibleWindowIDs(
                frontToBack: windows,
                selectableIDs: [1, 2]
            ),
            [1, 2]
        )
    }

    func testUnselectableFullscreenWindowOccludesEligibleWindows() {
        let windows = [
            ScreenshotWindowOcclusion(
                id: 10,
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
                alpha: 1,
                bundleIdentifier: "com.example.unsupported"
            ),
            ScreenshotWindowOcclusion(
                id: 1,
                frame: CGRect(x: 100, y: 100, width: 500, height: 300),
                alpha: 1,
                bundleIdentifier: "com.example.eligible"
            )
        ]

        XCTAssertEqual(
            ScreenshotWindowVisibility.visibleWindowIDs(
                frontToBack: windows,
                selectableIDs: [1]
            ),
            []
        )
    }
    func testPartiallyOccludedWindowIsSelectableOnlyInItsExposedRegion() {
        let windows = [
            ScreenshotWindowOcclusion(
                id: 10,
                frame: CGRect(x: 0, y: 0, width: 50, height: 100),
                alpha: 1,
                bundleIdentifier: "com.example.unsupported"
            ),
            ScreenshotWindowOcclusion(
                id: 1,
                frame: CGRect(x: 0, y: 0, width: 100, height: 100),
                alpha: 1,
                bundleIdentifier: "com.example.eligible"
            )
        ]
        let visibleRegions = ScreenshotWindowVisibility.visibleRegionsByWindowID(
            frontToBack: windows,
            selectableIDs: [1]
        )
        let rearWindow = ScreenshotWindow(
            id: 1,
            title: "Rear",
            applicationName: "Example",
            frame: CGRect(x: 0, y: 0, width: 100, height: 100),
            screenFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            selectableRegions: [CGRect(x: 50, y: 0, width: 50, height: 100)]
        )

        XCTAssertEqual(visibleRegions[1], [CGRect(x: 50, y: 0, width: 50, height: 100)])
        XCTAssertNil(
            ScreenshotWindowHitTesting.frontmostWindowID(
                at: CGPoint(x: 25, y: 50),
                windows: [rearWindow]
            )
        )
        XCTAssertEqual(
            ScreenshotWindowHitTesting.frontmostWindowID(
                at: CGPoint(x: 75, y: 50),
                windows: [rearWindow]
            ),
            1
        )
    }

    func testWindowSpanningDisplaysHasSelectableRegionOnEachDisplay() throws {
        let window = ScreenshotWindowDescriptor(
            id: 1,
            title: "Spanning",
            applicationName: "Example",
            frame: CGRect(x: 50, y: 20, width: 100, height: 40)
        )
        let firstScreen = CGRect(x: 0, y: 0, width: 100, height: 100)
        let secondScreen = CGRect(x: 100, y: 0, width: 100, height: 100)
        let firstDisplayWindow = try XCTUnwrap(
            ScreenshotWindow.onDisplay(
                window,
                displayBounds: firstScreen,
                screenFrame: firstScreen,
                visibleQuartzRegions: nil
            )
        )
        let secondDisplayWindow = try XCTUnwrap(
            ScreenshotWindow.onDisplay(
                window,
                displayBounds: secondScreen,
                screenFrame: secondScreen,
                visibleQuartzRegions: nil
            )
        )

        XCTAssertEqual(firstDisplayWindow.selectionFrame, CGRect(x: 50, y: 40, width: 50, height: 40))
        XCTAssertEqual(secondDisplayWindow.selectionFrame, CGRect(x: 0, y: 40, width: 50, height: 40))
        XCTAssertEqual(
            ScreenshotWindowHitTesting.frontmostWindowID(
                at: CGPoint(x: 75, y: 50),
                windows: [firstDisplayWindow]
            ),
            1
        )
        XCTAssertEqual(
            ScreenshotWindowHitTesting.frontmostWindowID(
                at: CGPoint(x: 25, y: 50),
                windows: [secondDisplayWindow]
            ),
            1
        )
    }

    func testPartialOnScreenEnumerationExcludesUnconfirmedCandidates() {
        XCTAssertEqual(
            ScreenshotWindowVisibility.orderedCandidateIDs(
                candidateIDs: [1, 2, 3],
                frontToBackWindowIDs: [3, 1]
            ),
            [3, 1]
        )
        XCTAssertEqual(
            ScreenshotWindowVisibility.orderedCandidateIDs(
                candidateIDs: [1, 2, 3],
                frontToBackWindowIDs: []
            ),
            []
        )
        XCTAssertEqual(
            ScreenshotWindowVisibility.orderedCandidateIDs(
                candidateIDs: [1, 2, 3],
                frontToBackWindowIDs: nil
            ),
            [1, 2, 3]
        )
    }

    func testHitTestingPrefersFrontmostWindowContainingPointer() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let rearWindow = ScreenshotWindow(
            id: 1,
            title: "Rear",
            applicationName: "App",
            frame: CGRect(x: 10, y: 10, width: 100, height: 100),
            screenFrame: screenFrame
        )
        let frontWindow = ScreenshotWindow(
            id: 2,
            title: "Front",
            applicationName: "App",
            frame: CGRect(x: 20, y: 20, width: 80, height: 80),
            screenFrame: screenFrame
        )
        let overlapPoint = CGPoint(x: 50, y: 730)

        XCTAssertEqual(
            ScreenshotWindowHitTesting.frontmostWindowID(at: overlapPoint, windows: [frontWindow, rearWindow]),
            frontWindow.id
        )
        XCTAssertEqual(
            ScreenshotWindowHitTesting.frontmostWindowID(at: overlapPoint, windows: [rearWindow, frontWindow]),
            rearWindow.id
        )
        XCTAssertNil(ScreenshotWindowHitTesting.frontmostWindowID(at: .zero, windows: [frontWindow, rearWindow]))
    }
}
