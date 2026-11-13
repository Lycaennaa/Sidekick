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
        XCTAssertEqual(ToolsSettingsPage.tunables.title, "Tunables")
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
        let firstTool = try XCTUnwrap(findTextField("Convert clipboard images", in: clipboardView))
        XCTAssertEqual(heading.alignment, .left)
        XCTAssertEqual(section.alignment, .left)
        XCTAssertEqual(firstTool.alignment, .left)
        let headingX = heading.convert(.zero, to: clipboardView).x
        let sectionX = section.convert(.zero, to: clipboardView).x
        let firstToolX = firstTool.convert(.zero, to: clipboardView).x
        XCTAssertEqual(headingX, sectionX, accuracy: 1)
        XCTAssertEqual(headingX, firstToolX, accuracy: 1)
    }

    @MainActor
    func testClipboardFormatSelectorOffersAvailableEncoders() throws {
        let suiteName = "ClipboardFormatSelector.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        let picker = ClipboardImageOpeningApplicationPickerView(settings: settings)
        let clipboardView = ClipboardSettingsView(
            settings: settings,
            imageOpeningApplicationPicker: picker,
            clearURLsAvailable: false
        )
        let formats = ClipboardImageFormat.availableForEncoding
        let expectedTitles = formats.map(\.displayName)
        let formatPopup = try XCTUnwrap(findPopup(withTitles: expectedTitles, in: clipboardView))

        XCTAssertEqual(formatPopup.itemTitles, expectedTitles)
        let selectedFormat = try XCTUnwrap(formats.last)
        formatPopup.selectItem(at: try XCTUnwrap(formats.firstIndex(of: selectedFormat)))
        guard let action = formatPopup.action else {
            return XCTFail("Image output format selector has no action")
        }
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: formatPopup.target, from: formatPopup))
        XCTAssertEqual(settings.imageOutputFormat, selectedFormat)
    }

    func testTunablesInputsPersistCustomNumbers() throws {
        let suiteName = "TunablesSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        let view = TunablesSettingsView(settings: settings)
        let qualityOptions = ClipboardImageConversionPolicy.qualityPresets.map {
            "\(Int(($0 * 100).rounded()))%"
        }
        let clipboardQuality = try XCTUnwrap(
            findComboBox(withIdentifier: "Clipboard image quality percentage", in: view)
        )
        let screenshotQuality = try XCTUnwrap(
            findComboBox(withIdentifier: "Screenshot image quality percentage", in: view)
        )
        let utilityToastDuration = try XCTUnwrap(
            findComboBox(withIdentifier: "Utility toast duration in seconds", in: view)
        )
        let twitchToastDuration = try XCTUnwrap(
            findComboBox(withIdentifier: "Twitch toast duration in seconds", in: view)
        )
        let twitchPollFrequency = try XCTUnwrap(
            findComboBox(withIdentifier: "Twitch poll frequency in seconds", in: view)
        )

        XCTAssertEqual(comboTitles(clipboardQuality), qualityOptions)
        XCTAssertEqual(comboTitles(screenshotQuality), qualityOptions)
        XCTAssertEqual(comboTitles(utilityToastDuration), ["1.5", "2.5", "4", "6"])
        XCTAssertEqual(comboTitles(twitchToastDuration), ["4", "6", "8", "10", "15"])
        XCTAssertEqual(comboTitles(twitchPollFrequency), ["30", "60", "150", "300", "600"])
        for input in [
            clipboardQuality,
            screenshotQuality,
            utilityToastDuration,
            twitchToastDuration,
            twitchPollFrequency
        ] {
            XCTAssertTrue(input.isEditable)
            XCTAssertNotNil(input.delegate)
        }

        enter("62.5%", into: clipboardQuality)
        enter("37.5%", into: screenshotQuality)
        enter("3.25", into: utilityToastDuration)
        enter("17.5s", into: twitchToastDuration)
        enter("360s", into: twitchPollFrequency)

        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.clipboardImageQuality, 0.625)
        XCTAssertEqual(restored.screenshotImageQuality, 0.375)
        XCTAssertEqual(restored.toastDuration, 3.25)
        XCTAssertEqual(restored.twitchToastDuration, 17.5)
        XCTAssertEqual(restored.twitchPollInterval, 360)

        enter("120%", into: clipboardQuality)
        enter("29", into: twitchPollFrequency)
        XCTAssertEqual(settings.clipboardImageQuality, 0.625)
        XCTAssertEqual(settings.twitchPollInterval, 30)
    }

    private func findPopup(withTitles titles: [String], in view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton, popup.itemTitles == titles {
            return popup
        }
        for subview in view.subviews {
            if let popup = findPopup(withTitles: titles, in: subview) {
                return popup
            }
        }
        return nil
    }

    private func findComboBox(withIdentifier identifier: String, in view: NSView) -> NSComboBox? {
        if let comboBox = view as? NSComboBox, comboBox.identifier?.rawValue == identifier {
            return comboBox
        }
        for subview in view.subviews {
            if let match = findComboBox(withIdentifier: identifier, in: subview) {
                return match
            }
        }
        return nil
    }

    private func comboTitles(_ comboBox: NSComboBox) -> [String] {
        (0..<comboBox.numberOfItems).compactMap { comboBox.itemObjectValue(at: $0) as? String }
    }

    private func enter(_ value: String, into comboBox: NSComboBox) {
        comboBox.stringValue = value
        guard let view = comboBox.delegate as? TunablesSettingsView else {
            return XCTFail("Numeric settings input has no delegate")
        }
        view.controlTextDidEndEditing(
            Notification(name: Notification.Name("TunablesTextDidEndEditing"), object: comboBox)
        )
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
