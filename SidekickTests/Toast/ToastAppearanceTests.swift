import AppKit
import XCTest

@MainActor
final class ToastAppearanceTests: XCTestCase {
    func testVisibleToastRefreshesWhenThemeChangesWithoutChangingAppKitMode() throws {
        let application = NSApplication.shared
        let previousAppearance = AppTheme.appearance
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        defer {
            stack.hideAll()
            AppTheme.apply(previousAppearance)
        }

        AppTheme.apply(.dark)
        _ = try XCTUnwrap(coordinator.presentGeneral(
            ToastModel.generic(generation: 1),
            duration: .infinity,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        ))
        let panel = try XCTUnwrap(application.windows.compactMap { $0 as? ToastPanel }.last)

        AppTheme.apply(.amoledBlack)
        coordinator.refreshAppearance()

        let backgroundColor = try XCTUnwrap(panel.contentView?.layer?.backgroundColor)
        let surfaceColor = try XCTUnwrap(NSColor(cgColor: backgroundColor))
        XCTAssertTrue(surfaceColor.isEqual(NSColor.black))
    }
}
