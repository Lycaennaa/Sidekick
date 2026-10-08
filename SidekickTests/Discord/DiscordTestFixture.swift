import Foundation

enum DiscordTestFixture {
    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sidekick-Discord-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func makeApplication(at root: URL, originalArchive: Data) throws -> DiscordInstallTarget {
        let applicationURL = root.appendingPathComponent("Discord Development.app", isDirectory: true)
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.hnc.DiscordDevelopment",
            "CFBundlePackageType": "APPL",
            "CFBundleName": "Discord Development"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        try originalArchive.write(to: resourcesURL.appendingPathComponent("app.asar"))
        return try DiscordInstallTarget.resolve(applicationURL)
    }

    static func makeCustomApplication(at root: URL, originalArchive: Data = Data()) throws -> DiscordInstallTarget {
        try makeApplication(
            at: root,
            bundleIdentifier: "org.example.discord-fork",
            originalArchive: originalArchive
        )
    }

    static func makeApplication(
        at root: URL,
        bundleIdentifier: String,
        originalArchive: Data = Data()
    ) throws -> DiscordInstallTarget {
        let applicationURL = root.appendingPathComponent("My Discord Fork.app", isDirectory: true)
        let contentsURL = applicationURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundlePackageType": "APPL",
            "CFBundleDisplayName": "My Discord Fork"
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        try originalArchive.write(to: resourcesURL.appendingPathComponent("app.asar"))
        return try DiscordInstallTarget.resolve(applicationURL)
    }

    static func makeArtifact(in directory: URL, version: String = "v-test") throws -> EquicordReleaseArtifact {
        let archive = try EquicordAsarArchive.makeArchive(files: [
            "index.js": Data("module.exports = true;".utf8),
            "package.json": Data("{\"name\":\"equicord-test\"}".utf8)
        ])
        let fileURL = directory.appendingPathComponent("desktop-\(UUID().uuidString).asar")
        try archive.write(to: fileURL)
        return try EquicordReleaseArtifact(fileURL: fileURL, version: version)
    }
}
