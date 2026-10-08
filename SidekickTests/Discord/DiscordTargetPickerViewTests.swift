import Foundation
import XCTest

@MainActor
final class DiscordTargetPickerViewTests: XCTestCase {
    func testRefreshReplacesRemovedInstalledAppsWithCurrentDiscovery() {
        let original = makeTarget("/Applications/Discord.app", channel: .stable)
        let replacement = makeTarget("/Applications/Discord PTB.app", channel: .ptb)
        var discovered = [original]
        let picker = DiscordTargetPickerView(discoverTargets: { discovered })

        XCTAssertEqual(picker.selectedTarget, original)

        discovered = [replacement]
        picker.refresh()
        XCTAssertEqual(picker.selectedTarget, replacement)

        discovered = []
        picker.refresh()
        XCTAssertNil(picker.selectedTarget)
    }

    func testRefreshPreservesValidCustomTargetOutsideDiscovery() throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = try DiscordTestFixture.makeCustomApplication(at: root)
        let installed = makeTarget("/Applications/Discord.app", channel: .stable)
        let discovered = [installed]
        let picker = DiscordTargetPickerView(discoverTargets: { discovered })

        try picker.selectManuallyChosenApplication(at: custom.applicationURL)
        picker.refresh()

        XCTAssertEqual(picker.selectedTarget, custom)
    }

    func testRefreshClearsRemovedCustomSelectionUntilExplicitChoice() throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = try DiscordTestFixture.makeCustomApplication(at: root)
        let installed = makeTarget("/Applications/Discord.app", channel: .stable)
        let discovered = [installed]
        let picker = DiscordTargetPickerView(discoverTargets: { discovered })

        try picker.selectManuallyChosenApplication(at: custom.applicationURL)
        try FileManager.default.removeItem(at: custom.applicationURL)
        picker.refresh()
        XCTAssertNil(picker.selectedTarget)

        picker.refresh()
        XCTAssertNil(picker.selectedTarget)
    }

    func testRefreshPreservesManuallyChosenSupportedChannelOutsideDiscovery() throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try DiscordTestFixture.makeApplication(
            at: root,
            bundleIdentifier: "com.hnc.Discord"
        )
        let discovered = makeTarget("/Applications/Discord PTB.app", channel: .ptb)
        let picker = DiscordTargetPickerView(discoverTargets: { [discovered] })

        try picker.selectManuallyChosenApplication(at: selected.applicationURL)
        picker.refresh()

        XCTAssertEqual(selected.channel, .stable)
        XCTAssertEqual(picker.selectedTarget, selected)
    }

    private func makeTarget(_ path: String, channel: DiscordInstallTarget.Channel) -> DiscordInstallTarget {
        DiscordInstallTarget(
            applicationURL: URL(fileURLWithPath: path, isDirectory: true),
            channel: channel,
            bundleIdentifier: channel.bundleIdentifier ?? "org.example.discord-fork",
            displayName: path
        )
    }
}
