import Foundation

struct EquicordSourceTools: Sendable {
    let git: URL
    let node: URL
    let pnpm: URL
}

enum EquicordSourceBuildError: LocalizedError {
    case missingTool(String)
    case invalidCheckout
    case sourceDestinationExists
    case userPluginInstallerMissing
    case sourcePluginChanged
    case commandFailed(String, Int32)
    case buildOutputUnavailable
    case cleanupFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingTool(let tool):
            "Install Git, Node.js 22 or newer, and pnpm 12.8.1, then restart Sidekick. Missing: \(tool)."
        case .invalidCheckout:
            "The retained Equicord source is not a recognized upstream checkout. It was left untouched."
        case .sourceDestinationExists:
            "The Equicord source folder appeared during cloning. No existing files were overwritten."
        case .userPluginInstallerMissing:
            "The retained checkout has no supported UserpluginInstaller dev plugin source."
        case .sourcePluginChanged:
            "The UserpluginInstaller source changed during preparation. No source edit was written."
        case .commandFailed(let command, let status):
            "\(command) failed with exit status \(status). " +
                "Open the retained source folder and run the command in Terminal to inspect details."
        case .buildOutputUnavailable:
            "The source build did not produce a regular dist/desktop.asar archive."
        case .cleanupFailed(let path):
            "Sidekick could not clean up its temporary clone at \(path)."
        }
    }
}

@MainActor
final class EquicordSourceBuilder {
    typealias RunCommand = @MainActor @Sendable (URL, [String], URL, UInt64) async throws -> Int32

    private let fileManager: FileManager
    private let commandRunner: EquicordSourceCommandRunner
    private let executeCommand: RunCommand
    private let supportDirectoryURL: URL
    private var operationGeneration: UInt64 = 0

    let sourceDirectoryURL: URL

    init(
        supportDirectory: URL? = nil,
        tools: EquicordSourceTools? = nil,
        fileManager: FileManager = .default,
        runCommand: RunCommand? = nil
    ) {
        self.fileManager = fileManager
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        let sidekickSupport = supportDirectory
            ?? applicationSupport.appendingPathComponent("Sidekick", isDirectory: true)
        supportDirectoryURL = sidekickSupport
        sourceDirectoryURL = sidekickSupport.appendingPathComponent("EquicordSource", isDirectory: true)

        let commandRunner = EquicordSourceCommandRunner()
        self.commandRunner = commandRunner
        if let runCommand {
            self.executeCommand = runCommand
        } else {
            self.executeCommand = { executable, arguments, directory, generation in
                try await commandRunner.run(
                    executable: executable,
                    arguments: arguments,
                    directory: directory,
                    operationGeneration: generation
                )
            }
        }
        injectedTools = tools
    }

    private let injectedTools: EquicordSourceTools?

    var hasSource: Bool {
        fileManager.fileExists(atPath: sourceDirectoryURL.appendingPathComponent("package.json").path)
    }

    func cancel() {
        let cancelledGeneration = operationGeneration
        operationGeneration &+= 1
        let commandRunner = self.commandRunner
        Task { await commandRunner.cancelCurrent(operationGeneration: cancelledGeneration) }
    }

    func build(progress: @escaping (String) -> Void) async throws -> EquicordReleaseArtifact {
        operationGeneration &+= 1
        let generation = operationGeneration
        try fileManager.createDirectory(at: supportDirectoryURL, withIntermediateDirectories: true)
        let tools = try injectedTools ?? resolveTools()
        progress("Checking Node.js…")
        try await runCommand(tools.node, ["--version"], supportDirectoryURL, generation: generation)

        if !hasSource {
            try await cloneSource(using: tools.git, generation: generation, progress: progress)
        }
        let version = try validateCheckout(at: sourceDirectoryURL)
        let userPluginInstallerEnabled = try enableUserPluginInstallerByDefault()
        progress(userPluginInstallerEnabled
            ? "UserpluginInstaller is default-enabled for new profiles."
            : "The retained source defines its own UserpluginInstaller default.")

        progress("Installing locked dependencies from cache where possible…")
        try await runCommand(
            tools.pnpm,
            ["install", "--frozen-lockfile", "--prefer-offline"],
            sourceDirectoryURL,
            generation: generation
        )

        let archiveURL = sourceDirectoryURL.appendingPathComponent("dist/desktop.asar")
        try removeGeneratedArchive(at: archiveURL)
        progress("Building Equicord development bundle…")
        try await runCommand(
            tools.pnpm,
            ["build", "--dev"],
            sourceDirectoryURL,
            generation: generation
        )
        try checkGeneration(generation)

        guard let values = try? archiveURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw EquicordSourceBuildError.buildOutputUnavailable
        }
        return try EquicordReleaseArtifact(
            fileURL: archiveURL,
            version: "dev-\(version)",
            lifetime: .retainedSource
        )
    }

    private func cloneSource(
        using git: URL,
        generation: UInt64,
        progress: (String) -> Void
    ) async throws {
        try fileManager.createDirectory(at: supportDirectoryURL, withIntermediateDirectories: true)
        let stagingURL = supportDirectoryURL.appendingPathComponent(
            ".EquicordSource-\(UUID().uuidString)",
            isDirectory: true
        )

        do {
            progress("Cloning Equicord main (shallow checkout)…")
            try await runCommand(
                git,
                ["clone", "--depth", "1", "--single-branch", "--branch", "main", "https://github.com/Equicord/Equicord.git", stagingURL.path],
                supportDirectoryURL,
                generation: generation
            )
            _ = try validateCheckout(at: stagingURL)
            guard !fileManager.fileExists(atPath: sourceDirectoryURL.path) else {
                throw EquicordSourceBuildError.sourceDestinationExists
            }
            try fileManager.moveItem(at: stagingURL, to: sourceDirectoryURL)
        } catch {
            do {
                try removeIfPresent(stagingURL)
            } catch {
                throw EquicordSourceBuildError.cleanupFailed(stagingURL.path)
            }
            throw error
        }
    }

    private func runCommand(
        _ executable: URL,
        _ arguments: [String],
        _ directory: URL,
        generation: UInt64
    ) async throws {
        try checkGeneration(generation)
        let status: Int32
        do {
            status = try await executeCommand(executable, arguments, directory, generation)
        } catch {
            try checkGeneration(generation)
            throw error
        }
        try checkGeneration(generation)
        guard status == 0 else {
            throw EquicordSourceBuildError.commandFailed(
                "\(executable.lastPathComponent) \(arguments.joined(separator: " "))",
                status
            )
        }
    }

    private func checkGeneration(_ expected: UInt64) throws {
        try Task.checkCancellation()
        guard expected == operationGeneration else { throw CancellationError() }
    }

    private func validateCheckout(at directory: URL) throws -> String {
        let gitDirectory = directory.appendingPathComponent(".git", isDirectory: true)
        let packageURL = directory.appendingPathComponent("package.json")
        guard fileManager.fileExists(atPath: gitDirectory.path),
              let data = try? Data(contentsOf: packageURL),
              let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              package["name"] as? String == "equicord",
              let repository = package["repository"] as? [String: Any],
              repository["url"] as? String == "git+https://github.com/Equicord/Equicord.git",
              let version = package["version"] as? String else {
            throw EquicordSourceBuildError.invalidCheckout
        }
        return version
    }

    private func enableUserPluginInstallerByDefault() throws -> Bool {
        let pluginURL = sourceDirectoryURL.appendingPathComponent(
            "src/equicordplugins/userpluginInstaller.dev/index.tsx"
        )
        guard let original = try? String(contentsOf: pluginURL, encoding: .utf8),
              let declaration = original.range(of: "name: \"UserpluginInstaller\",") else {
            throw EquicordSourceBuildError.userPluginInstallerMissing
        }

        let pluginRange = original.startIndex..<declaration.lowerBound
        guard let pluginStart = original.range(
            of: "definePlugin({",
            options: .backwards,
            range: pluginRange
        )?.lowerBound else {
            throw EquicordSourceBuildError.userPluginInstallerMissing
        }
        let pluginRemainder = declaration.upperBound..<original.endIndex
        guard let pluginEnd = original.range(of: "\n});", range: pluginRemainder)?.lowerBound else {
            throw EquicordSourceBuildError.userPluginInstallerMissing
        }
        let pluginDeclaration = pluginStart..<pluginEnd
        let nameLineStart = original[..<declaration.lowerBound].lastIndex(of: "\n")
            .map { original.index(after: $0) } ?? pluginStart
        let nameIndentation = original[nameLineStart..<declaration.lowerBound]
            .prefix { $0 == " " || $0 == "\t" }
        let propertyPrefix = "\n\(nameIndentation)enabledByDefault"
        var searchRange = pluginDeclaration
        while let defaultSetting = original.range(of: propertyPrefix, range: searchRange) {
            let property = original[defaultSetting.upperBound..<pluginEnd].drop(while: \.isWhitespace)
            if property.first == ":" {
                return property.dropFirst().drop(while: \.isWhitespace).hasPrefix("true")
            }
            searchRange = defaultSetting.upperBound..<pluginEnd
        }

        var updated = original
        updated.replaceSubrange(
            declaration,
            with: "name: \"UserpluginInstaller\",\n\(nameIndentation)enabledByDefault: true,"
        )
        guard (try? String(contentsOf: pluginURL, encoding: .utf8)) == original else {
            throw EquicordSourceBuildError.sourcePluginChanged
        }
        try updated.write(to: pluginURL, atomically: true, encoding: .utf8)
        return true
    }

    private func resolveTools() throws -> EquicordSourceTools {
        EquicordSourceTools(
            git: try resolveExecutable(named: "git"),
            node: try resolveExecutable(named: "node"),
            pnpm: try resolveExecutable(named: "pnpm")
        )
    }

    private func resolveExecutable(named name: String) throws -> URL {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"])
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw EquicordSourceBuildError.missingTool(name)
    }

    private func removeGeneratedArchive(at url: URL) throws {
        try removeIfPresent(url)
    }

    private func removeIfPresent(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try fileManager.removeItem(at: url)
    }
}
