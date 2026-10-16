import AppKit
import CoreGraphics

struct ScreenshotWindow: Identifiable {
    let id: CGWindowID
    let title: String
    let applicationName: String
    let frame: CGRect
    let screenFrame: CGRect
    let selectableRegions: [CGRect]

    var appKitFrame: CGRect {
        CGRect(
            x: screenFrame.minX + frame.minX,
            y: screenFrame.maxY - frame.minY - frame.height,
            width: frame.width,
            height: frame.height
        )
    }

    var selectionFrame: CGRect {
        CGRect(
            x: appKitFrame.minX - screenFrame.minX,
            y: appKitFrame.minY - screenFrame.minY,
            width: frame.width,
            height: frame.height
        )
    }

    init(
        id: CGWindowID,
        title: String,
        applicationName: String,
        frame: CGRect,
        screenFrame: CGRect,
        selectableRegions: [CGRect]? = nil
    ) {
        self.id = id
        self.title = title
        self.applicationName = applicationName
        self.frame = frame
        self.screenFrame = screenFrame
        self.selectableRegions = selectableRegions ?? [
            CGRect(
                x: frame.minX,
                y: screenFrame.height - frame.minY - frame.height,
                width: frame.width,
                height: frame.height
            )
        ]
    }

    static func onDisplay(
        _ window: ScreenshotWindowDescriptor,
        displayBounds: CGRect,
        screenFrame: CGRect,
        visibleQuartzRegions: [CGRect]?
    ) -> ScreenshotWindow? {
        let displayFrame = window.frame.intersection(displayBounds)
        guard !displayFrame.isNull, !displayFrame.isEmpty else { return nil }
        let quartzRegions = visibleQuartzRegions ?? [displayFrame]
        let selectionRegions = quartzRegions.compactMap { region -> CGRect? in
            let clippedRegion = region.intersection(displayFrame)
            guard !clippedRegion.isNull, !clippedRegion.isEmpty else { return nil }
            return CGRect(
                x: clippedRegion.minX - displayBounds.minX,
                y: screenFrame.height - clippedRegion.maxY + displayBounds.minY,
                width: clippedRegion.width,
                height: clippedRegion.height
            )
        }
        guard !selectionRegions.isEmpty else { return nil }
        return ScreenshotWindow(
            id: window.id,
            title: window.title,
            applicationName: window.applicationName,
            frame: CGRect(
                x: displayFrame.minX - displayBounds.minX,
                y: displayFrame.minY - displayBounds.minY,
                width: displayFrame.width,
                height: displayFrame.height
            ),
            screenFrame: screenFrame,
            selectableRegions: selectionRegions
        )
    }
}

struct ScreenshotWindowDescriptor {
    let id: CGWindowID
    let title: String
    let applicationName: String
    let frame: CGRect
}

enum ScreenshotWindowHitTesting {
    static func frontmostWindowID(at point: CGPoint, windows: [ScreenshotWindow]) -> CGWindowID? {
        windows.first(where: { window in
            window.selectableRegions.contains(where: { $0.contains(point) })
        })?.id
    }
}

struct ScreenshotWindowOcclusion {
    let id: CGWindowID
    let frame: CGRect
    let alpha: CGFloat
    let bundleIdentifier: String?
}

enum ScreenshotWindowVisibility {
    private static let ignoredOccluderBundleIDs = ScreenshotWindowCandidate.ignoredSystemBundleIDs

    static func visibleWindowIDs(
        frontToBack windows: [ScreenshotWindowOcclusion],
        selectableIDs: Set<CGWindowID>
    ) -> Set<CGWindowID> {
        Set(visibleRegionsByWindowID(frontToBack: windows, selectableIDs: selectableIDs).keys)
    }

    static func visibleRegionsByWindowID(
        frontToBack windows: [ScreenshotWindowOcclusion],
        selectableIDs: Set<CGWindowID>
    ) -> [CGWindowID: [CGRect]] {
        var visibleRegions: [CGWindowID: [CGRect]] = [:]
        var opaqueFrames: [CGRect] = []
        for window in windows where !window.frame.isEmpty {
            if let bundleIdentifier = window.bundleIdentifier,
               ignoredOccluderBundleIDs.contains(bundleIdentifier) {
                continue
            }
            if selectableIDs.contains(window.id) {
                let regions = uncoveredRegions(window.frame, coveredBy: opaqueFrames)
                if !regions.isEmpty {
                    visibleRegions[window.id] = regions
                }
            }
            if window.alpha >= 1 {
                opaqueFrames.append(window.frame)
            }
        }
        return visibleRegions
    }

    static func orderedCandidateIDs(
        candidateIDs: [CGWindowID],
        frontToBackWindowIDs: [CGWindowID]?
    ) -> [CGWindowID] {
        guard let frontToBackWindowIDs else { return candidateIDs }
        let candidateSet = Set(candidateIDs)
        return frontToBackWindowIDs.filter(candidateSet.contains)
    }

    private static func uncoveredRegions(_ frame: CGRect, coveredBy occluders: [CGRect]) -> [CGRect] {
        var uncovered = [frame]
        for occluder in occluders where frame.intersects(occluder) {
            uncovered = uncovered.flatMap { rectangle in
                let overlap = rectangle.intersection(occluder)
                guard !overlap.isNull, !overlap.isEmpty else { return [rectangle] }
                return [
                    CGRect(
                        x: rectangle.minX,
                        y: rectangle.minY,
                        width: rectangle.width,
                        height: overlap.minY - rectangle.minY
                    ),
                    CGRect(
                        x: rectangle.minX,
                        y: overlap.maxY,
                        width: rectangle.width,
                        height: rectangle.maxY - overlap.maxY
                    ),
                    CGRect(
                        x: rectangle.minX,
                        y: overlap.minY,
                        width: overlap.minX - rectangle.minX,
                        height: overlap.height
                    ),
                    CGRect(
                        x: overlap.maxX,
                        y: overlap.minY,
                        width: rectangle.maxX - overlap.maxX,
                        height: overlap.height
                    )
                ].filter { !$0.isEmpty }
            }
            if uncovered.isEmpty { return [] }
        }
        return uncovered
    }
}
struct ScreenshotWindowCandidate {
    static let ignoredSystemBundleIDs: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.wallpaper",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter",
        "com.apple.Spotlight"
    ]

    let frame: CGRect
    let isOnScreen: Bool
    let title: String
    let appName: String
    let bundleID: String?
    let hasOwningApplication: Bool
    let windowLayer: Int
    let isOwnAppWindow: Bool

    var isSelectable: Bool {
        let isSystemMenuBar = windowLayer == Int(CGWindowLevelForKey(.mainMenuWindow))
        let screenSaverWindowLayer = Int(CGWindowLevelForKey(.screenSaverWindow))
        let isOwnFullscreenCapture = isOwnAppWindow && windowLayer == screenSaverWindowLayer
        let isElevatedApplicationWindow = hasOwningApplication
            && windowLayer > 0
            && windowLayer < screenSaverWindowLayer
        let isEligibleLayer = windowLayer == 0
            || isOwnAppWindow
            || isElevatedApplicationWindow
        let isIgnoredSystemBundle = bundleID.map { Self.ignoredSystemBundleIDs.contains($0) } ?? false
        return !isSystemMenuBar
            && !isOwnFullscreenCapture
            && !isIgnoredSystemBundle
            && isOnScreen
            && frame.width > 100
            && frame.height > 50
            && isEligibleLayer
            && hasOwningApplication
            && (!title.isEmpty || !appName.isEmpty)
    }
}
