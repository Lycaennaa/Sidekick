import Foundation
import XCTest

@MainActor
final class DiscordInstallTargetTests: XCTestCase {
    func testResolveAcceptsSelectedCompatibleAppWithUnknownBundleIdentifier() throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let appURL = root.appendingPathComponent("My Discord Fork.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": "org.example.discord-fork",
            "CFBundlePackageType": "APPL",
            "CFBundleDisplayName": "My Discord Fork"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        let archive = try EquicordAsarArchive.makeArchive(files: [
            "index.js": Data("module.exports = true;".utf8),
            "package.json": Data("{\"name\":\"discord-fork\"}".utf8)
        ])
        try archive.write(to: resourcesURL.appendingPathComponent("app.asar"))

        let target = try DiscordInstallTarget.resolve(appURL)

        XCTAssertEqual(target.channel, .custom)
        XCTAssertEqual(target.bundleIdentifier, "org.example.discord-fork")
        XCTAssertEqual(target.displayName, "My Discord Fork")
        XCTAssertEqual(target.appArchiveURL, resourcesURL.appendingPathComponent("app.asar"))

        let artifact = try DiscordTestFixture.makeArtifact(in: root)
        try DiscordAppPatcher.install(target: target, artifact: artifact)
        XCTAssertEqual(DiscordAppPatcher.state(for: target), .installed)
        try DiscordAppPatcher.uninstall(target: target)
        XCTAssertEqual(try Data(contentsOf: target.appArchiveURL), archive)
    }
}
