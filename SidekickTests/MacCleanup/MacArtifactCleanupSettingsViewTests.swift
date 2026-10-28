import AppKit
import Foundation
import XCTest

@MainActor
final class MacArtifactCleanupSettingsViewTests: XCTestCase {
    func testDefaultModePopupUpdatesPersistedConfiguration() throws {
        let suiteName = "MacArtifactCleanupSettingsViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MacArtifactCleanupStore(defaults: defaults)
        let coordinator = MacArtifactCleanupCoordinator(store: store)
        let view = MacArtifactCleanupSettingsView(store: store, coordinator: coordinator)
        let popup = try XCTUnwrap(
            descendants(of: view).compactMap { $0 as? NSPopUpButton }.first
        )

        XCTAssertEqual(popup.selectedItem?.title, "Delete permanently")
        XCTAssertFalse(popup.itemTitles.contains("Use default"))

        popup.selectItem(withTitle: "Move to Trash")
        XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
        XCTAssertEqual(store.configuration.defaultMode, .moveToTrash)
        XCTAssertEqual(
            MacArtifactCleanupStore(defaults: defaults).configuration.defaultMode,
            .moveToTrash
        )
    }

    func testRootModeCanReturnToDefault() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let suiteName = "MacArtifactCleanupSettingsViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MacArtifactCleanupStore(defaults: defaults)
        XCTAssertTrue(store.addFolder(folder))
        let root = try XCTUnwrap(store.configuration.roots.first)
        store.setModeOverride(.moveToTrash, forRootID: root.id)
        let view = MacArtifactCleanupSettingsView(
            store: store,
            coordinator: MacArtifactCleanupCoordinator(store: store)
        )
        let popup = try XCTUnwrap(
            descendants(of: view)
                .compactMap { $0 as? NSPopUpButton }
                .first { $0.identifier?.rawValue == root.id.uuidString }
        )

        XCTAssertTrue(popup.itemTitles.contains("Use default"))
        popup.selectItem(withTitle: "Use default")
        XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
        let updatedRoot = try XCTUnwrap(store.configuration.roots.first { $0.id == root.id })
        XCTAssertNil(updatedRoot.modeOverride)
        XCTAssertEqual(store.configuration.mode(for: updatedRoot), .deletePermanently)
    }

    func testFailedFolderEnrollmentRemainsVisibleAfterRefresh() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let suiteName = "MacArtifactCleanupSettingsViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MacArtifactCleanupStore(defaults: defaults)
        XCTAssertTrue(store.addFolder(folder))
        let view = MacArtifactCleanupSettingsView(
            store: store,
            coordinator: MacArtifactCleanupCoordinator(store: store)
        )
        view.enrollFolder(folder)

        let error = try XCTUnwrap(
            descendants(of: view)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue.hasPrefix("That folder is already enrolled") }
        )
        XCTAssertEqual(
            error.stringValue,
            "That folder is already enrolled or its volume identity cannot be verified."
        )
    }

    private func makeTemporaryFolder() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-tmp/MacArtifactCleanupSettingsViewTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = directory.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants(of:))
    }
}
