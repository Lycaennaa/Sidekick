import AppKit
import Foundation

nonisolated struct DiscordInstallTarget: Hashable, Sendable {
    nonisolated enum Channel: CaseIterable, Hashable, Sendable {
        case stable
        case ptb
        case canary
        case development
        case custom

        nonisolated var bundleIdentifier: String? {
            switch self {
            case .stable: "com.hnc.Discord"
            case .ptb: "com.hnc.DiscordPTB"
            case .canary: "com.hnc.DiscordCanary"
            case .development: "com.hnc.DiscordDevelopment"
            case .custom: nil
            }
        }

        nonisolated var appBundleName: String? {
            switch self {
            case .stable: "Discord.app"
            case .ptb: "Discord PTB.app"
            case .canary: "Discord Canary.app"
            case .development: "Discord Development.app"
            case .custom: nil
            }
        }

        nonisolated var preferredDisplayName: String? {
            switch self {
            case .stable: "Discord"
            case .ptb: "Discord PTB"
            case .canary: "Discord Canary"
            case .development: "Discord Development"
            case .custom: nil
            }
        }

        nonisolated init(bundleIdentifier: String) {
            switch bundleIdentifier {
            case "com.hnc.Discord": self = .stable
            case "com.hnc.DiscordPTB": self = .ptb
            case "com.hnc.DiscordCanary": self = .canary
            case "com.hnc.DiscordDevelopment": self = .development
            default: self = .custom
            }
        }
    }

    let applicationURL: URL
    let channel: Channel
    let bundleIdentifier: String
    let displayName: String

    nonisolated var resourcesURL: URL { applicationURL.appendingPathComponent("Contents/Resources", isDirectory: true) }
    nonisolated var appArchiveURL: URL { resourcesURL.appendingPathComponent("app.asar") }
    nonisolated var backupURL: URL { resourcesURL.appendingPathComponent("_app.asar") }
    nonisolated var legacyBackupURL: URL { resourcesURL.appendingPathComponent("app.asar.sidekick-original") }
    nonisolated var payloadURL: URL { resourcesURL.appendingPathComponent("sidekick-equicord.asar") }
    nonisolated var restoreMarkerURL: URL { resourcesURL.appendingPathComponent("sidekick-restore.pending") }
    nonisolated var foreignBackupURLs: [URL] {
        ["app.asar.backup", "app.asar.original"].map {
            resourcesURL.appendingPathComponent($0)
        }
    }

    nonisolated static func resolve(
        _ candidate: URL,
        fileManager: FileManager = .default
    ) throws -> DiscordInstallTarget {
        let applicationURL = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard applicationURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              (try? applicationURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let bundle = Bundle(url: applicationURL),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let identifier = bundle.bundleIdentifier else {
            throw DiscordInstallTargetError.notApplicationBundle
        }

        let channel = Channel(bundleIdentifier: identifier)
        let declaredName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
        let displayName = channel.preferredDisplayName
            ?? declaredName
            ?? applicationURL.deletingPathExtension().lastPathComponent
        let target = DiscordInstallTarget(
            applicationURL: applicationURL,
            channel: channel,
            bundleIdentifier: identifier,
            displayName: displayName
        )
        guard let attributes = try? fileManager.attributesOfItem(atPath: target.appArchiveURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw DiscordInstallTargetError.missingApplicationArchive
        }
        return target
    }

    @MainActor
    static func discover(fileManager: FileManager = .default) -> [DiscordInstallTarget] {
        let supportedChannels = Channel.allCases.filter { $0 != .custom }
        let launchServicesURLs = supportedChannels.flatMap { channel -> [URL] in
            guard let bundleIdentifier = channel.bundleIdentifier else { return [] }
            return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier)
        }

        var applicationDirectories = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        if let userApplications = fileManager.urls(for: .applicationDirectory, in: .userDomainMask).first {
            applicationDirectories.append(userApplications)
        }
        let standardURLs = supportedChannels.flatMap { channel -> [URL] in
            guard let bundleName = channel.appBundleName else { return [] }
            return applicationDirectories.map { $0.appendingPathComponent(bundleName, isDirectory: true) }
        }

        var seen = Set<String>()
        return (launchServicesURLs + standardURLs).compactMap { candidate in
            guard let target = try? resolve(candidate, fileManager: fileManager),
                  seen.insert(target.applicationURL.path).inserted else {
                return nil
            }
            return target
        }
    }
}

enum DiscordInstallTargetError: LocalizedError {
    case notApplicationBundle
    case missingApplicationArchive

    var errorDescription: String? {
        switch self {
        case .notApplicationBundle:
            "Choose a macOS application bundle with a valid bundle identifier."
        case .missingApplicationArchive:
            "The selected app has no regular Contents/Resources/app.asar file."
        }
    }
}
