import AppKit
import XCTest

@MainActor
final class ToolsSettingsWindowTests: XCTestCase {
    func testAMOLEDAppearanceMakesSidebarSurfaceBlack() throws {
        _ = NSApplication.shared
        let previousAppearance = AppTheme.appearance
        defer { AppTheme.apply(previousAppearance) }

        AppTheme.apply(.amoledBlack)
        let sidebar = ToolsSidebarViewController()
        sidebar.loadViewIfNeeded()

        let scrollView = try XCTUnwrap(sidebar.view as? NSScrollView)
        let tableView = try XCTUnwrap(scrollView.documentView as? NSTableView)
        let backgroundColor = try XCTUnwrap(sidebar.view.layer?.backgroundColor)
        let surfaceColor = try XCTUnwrap(NSColor(cgColor: backgroundColor))
        XCTAssertTrue(surfaceColor.isEqual(NSColor.black))
        XCTAssertTrue(scrollView.drawsBackground)
        XCTAssertTrue(scrollView.backgroundColor.isEqual(NSColor.black))
        XCTAssertTrue(tableView.backgroundColor.isEqual(NSColor.black))
    }
}
