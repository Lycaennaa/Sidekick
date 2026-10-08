import Foundation
import XCTest

private actor SourceBuildGate {
    private var continuation: CheckedContinuation<Int32, Never>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    func waitForCommand() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func pauseCommand() async -> Int32 {
        started = true
        startContinuation?.resume()
        startContinuation = nil
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resumeCommand() {
        continuation?.resume(returning: 0)
        continuation = nil
    }
}

private actor SourceBuildCommandLog {
    private var arguments: [[String]] = []

    func append(_ command: [String]) {
        arguments.append(command)
    }

    func containsDevBuild() -> Bool {
        arguments.contains { $0.first == "build" && $0.contains("--dev") }
    }
}

@MainActor
final class EquicordSourceBuilderTests: XCTestCase {
    func testDefaultRunnerExecutesARealPlatformProcess() async throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let status = try await EquicordSourceCommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            directory: root,
            operationGeneration: 1
        )

        XCTAssertEqual(status, 0)
    }

    private func makeSourceBuilder(
        supportDirectory: URL,
        builtArchive: Data,
        commandLog: SourceBuildCommandLog,
        userPluginDisabled: Bool = false,
        userPluginDefaultBeforeName: Bool = false,
        pluginIndentation: String = "    ",
        unrelatedSettingAfterPlugin: String = ""
    ) -> EquicordSourceBuilder {
        let explicitDefault = userPluginDisabled ? "\(pluginIndentation)enabledByDefault: false,\n" : ""
        let explicitDefaultBeforeName = userPluginDefaultBeforeName ? explicitDefault : ""
        let explicitDefaultAfterName = userPluginDefaultBeforeName ? "" : explicitDefault
        let fakeCommand: EquicordSourceBuilder.RunCommand = { executable, arguments, directory, _ in
            await commandLog.append(arguments)
            if executable.lastPathComponent == "git", arguments.first == "clone",
               let clonePath = arguments.last {
                let checkout = URL(fileURLWithPath: clonePath, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: checkout.appendingPathComponent(".git", isDirectory: true),
                    withIntermediateDirectories: true
                )
                let package = [
                    "name": "equicord",
                    "version": "1.15.10.0",
                    "repository": ["url": "git+https://github.com/Equicord/Equicord.git"],
                    "packageManager": "pnpm@12.8.1"
                ] as [String: Any]
                let packageData = try JSONSerialization.data(withJSONObject: package)
                try packageData.write(to: checkout.appendingPathComponent("package.json"))

                let pluginDirectory = checkout.appendingPathComponent(
                    "src/equicordplugins/userpluginInstaller.dev",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
                let pluginSource = "export default definePlugin({\n" +
                    explicitDefaultBeforeName +
                    "\(pluginIndentation)name: \"UserpluginInstaller\",\n" +
                    explicitDefaultAfterName +
                    "\(pluginIndentation)description: \"test plugin\"\n});\n" +
                    unrelatedSettingAfterPlugin
                try pluginSource.write(
                    to: pluginDirectory.appendingPathComponent("index.tsx"),
                    atomically: true,
                    encoding: .utf8
                )
                return 0
            }
            if executable.lastPathComponent == "pnpm", arguments.first == "build" {
                let output = directory.appendingPathComponent("dist/desktop.asar")
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try builtArchive.write(to: output)
            }
            return 0
        }
        return EquicordSourceBuilder(
            supportDirectory: supportDirectory,
            tools: EquicordSourceTools(
                git: URL(fileURLWithPath: "/fake/git"),
                node: URL(fileURLWithPath: "/fake/node"),
                pnpm: URL(fileURLWithPath: "/fake/pnpm")
            ),
            runCommand: fakeCommand
        )
    }

    func testDevBuildRetainsSourceAndBuiltArchiveAfterDiscordInstall() async throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let supportDirectory = root.appendingPathComponent("Application Support", isDirectory: true)
        let builtArchive = try EquicordAsarArchive.makeArchive(files: [
            "index.js": Data("module.exports = 'equicord dev';".utf8)
        ])
        let commandLog = SourceBuildCommandLog()
        let builder = makeSourceBuilder(
            supportDirectory: supportDirectory,
            builtArchive: builtArchive,
            commandLog: commandLog
        )

        let artifact = try await builder.build(progress: { _ in })
        let target = try DiscordTestFixture.makeApplication(
            at: root,
            originalArchive: try EquicordAsarArchive.makeArchive(files: [
                "index.js": Data("module.exports = 'stock';".utf8)
            ])
        )

        try DiscordAppPatcher.install(target: target, artifact: artifact)

        XCTAssertEqual(artifact.lifetime, .retainedSource)
        let builtWithDevFlag = await commandLog.containsDevBuild()
        XCTAssertTrue(builtWithDevFlag)
        XCTAssertEqual(try Data(contentsOf: artifact.fileURL), builtArchive)
        let userPluginSourceURL = builder.sourceDirectoryURL
            .appendingPathComponent("src/equicordplugins/userpluginInstaller.dev/index.tsx")
        let userPluginSource = try String(contentsOf: userPluginSourceURL, encoding: .utf8)
        XCTAssertTrue(userPluginSource.contains("enabledByDefault: true"))
        let gitDirectoryURL = builder.sourceDirectoryURL.appendingPathComponent(".git")
        XCTAssertTrue(FileManager.default.fileExists(atPath: gitDirectoryURL.path))
        try DiscordAppPatcher.uninstall(target: target)
        XCTAssertEqual(try Data(contentsOf: artifact.fileURL), builtArchive)
    }

    func testSourceBuildPreservesExplicitUserPluginInstallerOptOut() async throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let supportDirectory = root.appendingPathComponent("Application Support", isDirectory: true)
        let archive = try EquicordAsarArchive.makeArchive(files: [
            "index.js": Data("module.exports = 'equicord dev';".utf8)
        ])
        let builder = makeSourceBuilder(
            supportDirectory: supportDirectory,
            builtArchive: archive,
            commandLog: SourceBuildCommandLog(),
            userPluginDisabled: true
        )

        _ = try await builder.build(progress: { _ in })

        let pluginURL = builder.sourceDirectoryURL
            .appendingPathComponent("src/equicordplugins/userpluginInstaller.dev/index.tsx")
        let pluginSource = try String(contentsOf: pluginURL, encoding: .utf8)
        XCTAssertTrue(pluginSource.contains("enabledByDefault: false"))
        XCTAssertFalse(pluginSource.contains("enabledByDefault: true"))
    }

    func testSourceBuildPreservesOptOutBeforeNameWithWhitespaceIndentation() async throws {
        for indentation in ["  ", "\t"] {
            let root = try DiscordTestFixture.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let archive = try EquicordAsarArchive.makeArchive(files: [
                "index.js": Data("module.exports = 'equicord dev';".utf8)
            ])
            let builder = makeSourceBuilder(
                supportDirectory: root.appendingPathComponent("Application Support", isDirectory: true),
                builtArchive: archive,
                commandLog: SourceBuildCommandLog(),
                userPluginDisabled: true,
                userPluginDefaultBeforeName: true,
                pluginIndentation: indentation
            )

            _ = try await builder.build(progress: { _ in })

            let pluginURL = builder.sourceDirectoryURL
                .appendingPathComponent("src/equicordplugins/userpluginInstaller.dev/index.tsx")
            let pluginSource = try String(contentsOf: pluginURL, encoding: .utf8)
            XCTAssertEqual(pluginSource.components(separatedBy: "enabledByDefault:").count - 1, 1)
            XCTAssertTrue(pluginSource.contains("\(indentation)enabledByDefault: false"))
            XCTAssertFalse(pluginSource.contains("enabledByDefault: true"))
        }
    }

    func testSourceBuildIgnoresUnrelatedDefaultAfterUserPluginDeclaration() async throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try EquicordAsarArchive.makeArchive(files: [
            "index.js": Data("module.exports = 'equicord dev';".utf8)
        ])
        let builder = makeSourceBuilder(
            supportDirectory: root.appendingPathComponent("Application Support", isDirectory: true),
            builtArchive: archive,
            commandLog: SourceBuildCommandLog(),
            unrelatedSettingAfterPlugin: "const anotherPlugin = { enabledByDefault: false };\n"
        )

        _ = try await builder.build(progress: { _ in })

        let pluginURL = builder.sourceDirectoryURL
            .appendingPathComponent("src/equicordplugins/userpluginInstaller.dev/index.tsx")
        let pluginSource = try String(contentsOf: pluginURL, encoding: .utf8)
        XCTAssertTrue(pluginSource.contains("name: \"UserpluginInstaller\",\n    enabledByDefault: true,"))
        XCTAssertTrue(pluginSource.contains("const anotherPlugin = { enabledByDefault: false };"))
    }

    func testCancellationDuringCloneDoesNotPromotePartialSource() async throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let supportDirectory = root.appendingPathComponent("Application Support", isDirectory: true)
        let gate = SourceBuildGate()
        let builder = EquicordSourceBuilder(
            supportDirectory: supportDirectory,
            tools: EquicordSourceTools(
                git: URL(fileURLWithPath: "/fake/git"),
                node: URL(fileURLWithPath: "/fake/node"),
                pnpm: URL(fileURLWithPath: "/fake/pnpm")
            ),
            runCommand: { executable, _, _, _ in
                if executable.lastPathComponent == "node" { return 0 }
                return await gate.pauseCommand()
            }
        )

        let operation = Task {
            try await builder.build(progress: { _ in })
        }
        await gate.waitForCommand()
        builder.cancel()
        await gate.resumeCommand()

        do {
            _ = try await operation.value
            XCTFail("A cancelled clone must not be promoted into the retained source folder.")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: builder.sourceDirectoryURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: supportDirectory.path), [])
    }
}
