import AppKit
import XCTest

@MainActor
final class ToolsContentViewControllerTests: XCTestCase {
    func testSidebarSelectionShowsCorrespondingSettingsPage() throws {
        let pages = ToolsSettingsPage.allCases.map { ($0, NSView()) }
        let pageHost = ToolsSettingsPageHost(pages: pages, selectedPage: .clipboard)

        let sidebar = ToolsSidebarViewController()
        sidebar.onSelection = { pageHost.select($0) }
        sidebar.loadViewIfNeeded()
        let tableView = try XCTUnwrap(findView(NSTableView.self, in: sidebar.view))
        XCTAssertEqual(ToolsSettingsPage.twitch.title, "Twitch")
        XCTAssertEqual(ToolsSettingsPage.permissions.title, "Permissions")

        for page in ToolsSettingsPage.allCases {
            tableView.selectRowIndexes(IndexSet(integer: page.rawValue), byExtendingSelection: false)

            XCTAssertEqual(pageHost.selectedPage, page)
            let visiblePageIdentifiers = pageHost.subviews
                .filter { !$0.isHidden }
                .compactMap { $0.identifier?.rawValue }
            XCTAssertEqual(visiblePageIdentifiers, [page.title])
        }
    }

    func testClipboardPageTitlesAndRowsShareLeadingEdge() throws {
        let suiteName = "ClipboardLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        let picker = ClipboardImageOpeningApplicationPickerView(settings: settings)
        let clipboardView = ClipboardSettingsView(
            settings: settings,
            imageOpeningApplicationPicker: picker,
            clearURLsAvailable: false
        )
        clipboardView.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        clipboardView.layoutSubtreeIfNeeded()

        let heading = try XCTUnwrap(findTextField("Clipboard", in: clipboardView))
        let section = try XCTUnwrap(findTextField("Clipboard tools", in: clipboardView))
        let firstTool = try XCTUnwrap(findTextField("Convert clipboard images to WebP", in: clipboardView))
        let clipboardNotifications = try XCTUnwrap(findTextField("Clipboard notifications", in: clipboardView))
        let toastDuration = try XCTUnwrap(findTextField("Toast duration", in: clipboardView))
        XCTAssertEqual(clipboardNotifications.stringValue, "Clipboard notifications")
        XCTAssertEqual(toastDuration.stringValue, "Toast duration")
        XCTAssertEqual(heading.alignment, .left)
        XCTAssertEqual(section.alignment, .left)
        XCTAssertEqual(firstTool.alignment, .left)
        let headingX = heading.convert(.zero, to: clipboardView).x
        let sectionX = section.convert(.zero, to: clipboardView).x
        let firstToolX = firstTool.convert(.zero, to: clipboardView).x
        XCTAssertEqual(headingX, sectionX, accuracy: 1)
        XCTAssertEqual(headingX, firstToolX, accuracy: 1)
    }

    private func findTextField(_ value: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue == value {
            return field
        }
        for subview in view.subviews {
            if let field = findTextField(value, in: subview) {
                return field
            }
        }
        return nil
    }

    private func findView<ViewType: NSView>(_ type: ViewType.Type, in view: NSView) -> ViewType? {
        if let match = view as? ViewType { return match }
        for subview in view.subviews {
            if let match = findView(type, in: subview) { return match }
        }
        return nil
    }
}
