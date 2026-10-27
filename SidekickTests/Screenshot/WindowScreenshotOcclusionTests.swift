import AppKit
import XCTest

@MainActor
final class WindowScreenshotOcclusionTests: XCTestCase {
    func testWindowSelectionOverlayDoesNotHideApplicationWindow() throws {
        let frame = CGRect(x: 0, y: 0, width: 480, height: 320)
        let ownerPID = ProcessInfo.processInfo.processIdentifier
        func windowInfo(id: CGWindowID, ownerPID: Int32, layer: Int) -> [String: Any] {
            [
                kCGWindowNumber as String: NSNumber(value: id),
                kCGWindowBounds as String: frame.dictionaryRepresentation,
                kCGWindowAlpha as String: NSNumber(value: 1),
                kCGWindowOwnerPID as String: NSNumber(value: ownerPID),
                kCGWindowLayer as String: NSNumber(value: layer)
            ]
        }
        let target = try XCTUnwrap(WindowScreenshotCapture.occlusionWindow(
            from: windowInfo(id: 1, ownerPID: ownerPID, layer: 0),
            bundleIdentifier: "com.example.application"
        ))
        let overlayInfo = windowInfo(
            id: 2,
            ownerPID: ownerPID,
            layer: Int(CGWindowLevelForKey(.screenSaverWindow))
        )
        let overlay = WindowScreenshotCapture.occlusionWindow(
            from: overlayInfo,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
        XCTAssertEqual(
            ScreenshotWindowVisibility.visibleRegionsByWindowID(
                frontToBack: [overlay, target].compactMap(\.self),
                selectableIDs: [target.id],
                displayBounds: [CGRect(x: 0, y: 0, width: 3_360, height: 1_890)]
            )[target.id],
            [frame],
            "The clear selection panels must not occlude the window beneath them"
        )

        var foreignOverlayInfo = overlayInfo
        foreignOverlayInfo[kCGWindowOwnerPID as String] = NSNumber(value: ownerPID + 1)
        let foreignOverlay = try XCTUnwrap(WindowScreenshotCapture.occlusionWindow(
            from: foreignOverlayInfo,
            bundleIdentifier: "com.example.other"
        ))
        XCTAssertNil(ScreenshotWindowVisibility.visibleRegionsByWindowID(
            frontToBack: [foreignOverlay, target],
            selectableIDs: [target.id],
            displayBounds: [CGRect(x: 0, y: 0, width: 3_360, height: 1_890)]
        )[target.id], "Other applications' opaque windows must still occlude capture targets")
    }

    func testElevatedDisplayCoveringOverlayKeepsSelectableWindows() throws {
        let display = CGRect(x: 0, y: 0, width: 3_360, height: 1_890)
        let targetFrame = CGRect(x: 106, y: 797, width: 1_400, height: 984)
        let overlay = try mappedWindow(id: 10_972, frame: display, layer: 2_147_483_629)
        let target = try mappedWindow(id: 10_813, frame: targetFrame, layer: 0)

        XCTAssertEqual(
            ScreenshotWindowVisibility.visibleRegionsByWindowID(
                frontToBack: [overlay, target],
                selectableIDs: [target.id],
                displayBounds: [display]
            ),
            [target.id: [targetFrame]]
        )
    }

    func testOrdinaryFullscreenWindowStillOccludesWindowsBehindIt() throws {
        let display = CGRect(x: 0, y: 0, width: 3_360, height: 1_890)
        let fullscreen = try mappedWindow(id: 1, frame: display, layer: 0)
        let target = try mappedWindow(id: 2, frame: CGRect(x: 106, y: 797, width: 1_400, height: 984), layer: 0)

        XCTAssertEqual(
            ScreenshotWindowVisibility.visibleRegionsByWindowID(
                frontToBack: [fullscreen, target],
                selectableIDs: [fullscreen.id, target.id],
                displayBounds: [display]
            ),
            [fullscreen.id: [display]]
        )
    }

    func testElevatedPartialDisplayWindowStillOccludesItsCoveredRegion() throws {
        let display = CGRect(x: 0, y: 0, width: 3_360, height: 1_890)
        let overlay = try mappedWindow(
            id: 1, frame: CGRect(x: 0, y: 0, width: 1_680, height: 1_890), layer: 2_147_483_629
        )
        let target = try mappedWindow(id: 2, frame: display, layer: 0)

        XCTAssertEqual(
            ScreenshotWindowVisibility.visibleRegionsByWindowID(
                frontToBack: [overlay, target],
                selectableIDs: [target.id],
                displayBounds: [display]
            ),
            [target.id: [CGRect(x: 1_680, y: 0, width: 1_680, height: 1_890)]]
        )
    }

    func testDisplayCoveringOverlayKeepsOcclusionOnPartiallyCoveredAdjacentDisplay() throws {
        let firstDisplay = CGRect(x: 0, y: 0, width: 3_360, height: 1_890)
        let secondDisplay = CGRect(x: 3_360, y: 0, width: 1_440, height: 900)
        let overlay = try mappedWindow(
            id: 1, frame: CGRect(x: 0, y: 0, width: 4_000, height: 1_890), layer: 2_147_483_629
        )
        let firstTarget = try mappedWindow(
            id: 2, frame: CGRect(x: 100, y: 100, width: 480, height: 320), layer: 0
        )
        let secondTarget = try mappedWindow(id: 3, frame: secondDisplay, layer: 0)

        XCTAssertEqual(
            ScreenshotWindowVisibility.visibleRegionsByWindowID(
                frontToBack: [overlay, secondTarget, firstTarget],
                selectableIDs: [firstTarget.id, secondTarget.id],
                displayBounds: [firstDisplay, secondDisplay]
            ),
            [
                firstTarget.id: [CGRect(x: 100, y: 100, width: 480, height: 320)],
                secondTarget.id: [CGRect(x: 4_000, y: 0, width: 800, height: 900)]
            ]
        )
    }

    private func mappedWindow(id: CGWindowID, frame: CGRect, layer: Int) throws -> ScreenshotWindowOcclusion {
        try XCTUnwrap(WindowScreenshotCapture.occlusionWindow(
            from: [
                kCGWindowNumber as String: NSNumber(value: id),
                kCGWindowBounds as String: frame.dictionaryRepresentation,
                kCGWindowAlpha as String: NSNumber(value: 1),
                kCGWindowOwnerPID as String: NSNumber(value: ProcessInfo.processInfo.processIdentifier + 1),
                kCGWindowLayer as String: NSNumber(value: layer)
            ],
            bundleIdentifier: "com.example.application"
        ))
    }
}
