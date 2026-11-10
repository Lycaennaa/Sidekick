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

    func testRootModeCanReturnToDefault() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let suiteName = "MacArtifactCleanupSettingsViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MacArtifactCleanupStore(defaults: defaults)
        let addedFolder = await store.addFolder(folder)
        XCTAssertTrue(addedFolder)
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

    func testEveryEnrolledFolderHasItsOwnCleanNowButton() async throws {
        let firstFolder = try makeTemporaryFolder()
        let secondFolder = try makeTemporaryFolder()
        defer {
            try? FileManager.default.removeItem(at: firstFolder.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondFolder.deletingLastPathComponent())
        }
        let suiteName = "MacArtifactCleanupSettingsViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MacArtifactCleanupStore(defaults: defaults)
        let firstAdded = await store.addFolder(firstFolder)
        let secondAdded = await store.addFolder(secondFolder)
        XCTAssertTrue(firstAdded)
        XCTAssertTrue(secondAdded)
        let view = MacArtifactCleanupSettingsView(
            store: store,
            coordinator: MacArtifactCleanupCoordinator(store: store)
        )
        let rootIDs = Set(store.configuration.roots.map(\.id.uuidString))
        let cleanNowButtons = descendants(of: view)
            .compactMap { $0 as? NSButton }
            .filter { $0.title == "Clean Now" }

        XCTAssertEqual(cleanNowButtons.count, rootIDs.count)
        XCTAssertEqual(Set(cleanNowButtons.compactMap(\.identifier?.rawValue)), rootIDs)
        XCTAssertTrue(cleanNowButtons.allSatisfy { $0.target === view })
    }

    func testFailedFolderEnrollmentRemainsVisibleAfterRefresh() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let suiteName = "MacArtifactCleanupSettingsViewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MacArtifactCleanupStore(defaults: defaults)
        let addedFolder = await store.addFolder(folder)
        XCTAssertTrue(addedFolder)
        let view = MacArtifactCleanupSettingsView(
            store: store,
            coordinator: MacArtifactCleanupCoordinator(store: store)
        )
        await view.enrollFolder(folder)

        let error = try XCTUnwrap(
            descendants(of: view)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue.hasPrefix("That folder is already enrolled") }
        )
        XCTAssertEqual(
            error.stringValue,
            "That folder is already enrolled or is on an unsupported volume."
        )
    }

    func testCleanupPromptIsNonmodalAndRunsTheSelectedButtonAction() throws {
        var selectedButton: String?
        var dismissCount = 0
        let prompt = MacArtifactCleanupPromptPanel(
            title: "Enroll Archive for Mac cleanup?",
            detail: "Sidekick monitors enrolled locations.",
            buttons: [
                .init(title: "Not Now"),
                .init(title: "Enroll Volume", action: { selectedButton = "Enroll Volume" })
            ]
        )
        prompt.onDismiss = { dismissCount += 1 }
        prompt.show()
        defer { prompt.close() }

        XCTAssertTrue(prompt.window.isVisible)
        XCTAssertNil(NSApp.modalWindow)
        let contentView = try XCTUnwrap(prompt.window.contentView)
        let enrollButton = try XCTUnwrap(
            descendants(of: contentView).compactMap { $0 as? NSButton }
                .first { $0.title == "Enroll Volume" }
        )
        enrollButton.performClick(nil)

        XCTAssertEqual(selectedButton, "Enroll Volume")
        XCTAssertEqual(dismissCount, 1)
        XCTAssertFalse(prompt.window.isVisible)
    }

    func testClosingCleanupPromptDismissesWithoutRunningButtonAction() {
        var selectedButton = false
        var dismissCount = 0
        var closeCount = 0
        let prompt = MacArtifactCleanupPromptPanel(
            title: "Enroll Archive for Mac cleanup?",
            detail: "Sidekick monitors enrolled locations.",
            buttons: [.init(title: "Enroll Volume", action: { selectedButton = true })]
        )
        prompt.onDismiss = { dismissCount += 1 }
        prompt.onClose = { closeCount += 1 }
        prompt.show()
        prompt.close()

        XCTAssertFalse(prompt.window.isVisible)
        XCTAssertFalse(selectedButton)
        XCTAssertEqual(dismissCount, 1)
        XCTAssertEqual(closeCount, 1)
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
