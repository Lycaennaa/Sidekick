import Foundation
import XCTest

private actor EquicordDownloadGate {
    private var downloadContinuation: CheckedContinuation<EquicordReleaseArtifact, Error>?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    func download() async throws -> EquicordReleaseArtifact {
        started = true
        startContinuation?.resume()
        startContinuation = nil
        return try await withCheckedThrowingContinuation { continuation in
            downloadContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func release(_ artifact: EquicordReleaseArtifact) {
        downloadContinuation?.resume(returning: artifact)
        downloadContinuation = nil
    }
}

// Immutable semaphores own cross-thread state; each test releases the worker before the gate leaves scope.
private final class PatchExecutionGate: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func pause() {
        started.signal()
        resume.wait()
    }

    func waitUntilStarted() async -> Bool {
        await withCheckedContinuation { continuation in
            let semaphore = started
            DispatchQueue.global().async {
                let didStart = semaphore.wait(timeout: .now() + .seconds(5))
                continuation.resume(returning: didStart == .success)
            }
        }
    }

    func release() {
        resume.signal()
    }
}

private actor DiscordOperationCounter {
    private var value = 0

    func increment() {
        value += 1
    }

    func count() -> Int { value }
}

@MainActor
final class DiscordInstallerCoordinatorTests: XCTestCase {
    func testNewerOperationOwnershipPreventsPostDownloadMutation() async throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let originalArchive = try EquicordAsarArchive.makeArchive(files: [
            "index.js": Data("module.exports = 'stock';".utf8)
        ])
        let target = try DiscordTestFixture.makeApplication(at: root, originalArchive: originalArchive)
        let artifact = try DiscordTestFixture.makeArtifact(in: root)
        let gate = EquicordDownloadGate()
        let coordinator = DiscordInstallerCoordinator(downloadLatest: {
            try await gate.download()
        })

        let operation = Task {
            try await coordinator.install(target: target)
        }
        await gate.waitUntilStarted()
        coordinator.cancelActiveOperation()
        await gate.release(artifact)

        do {
            _ = try await operation.value
            XCTFail("A superseded install must not modify Discord.")
        } catch is CancellationError {
        }

        XCTAssertEqual(try Data(contentsOf: target.appArchiveURL), originalArchive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.payloadURL.path))
    }
    func testCancellationWhilePatchRunsOffMainActorLeavesDiscordUntouched() async throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let originalArchive = try EquicordAsarArchive.makeArchive(files: [
            "index.js": Data("module.exports = 'stock';".utf8)
        ])
        let target = try DiscordTestFixture.makeApplication(at: root, originalArchive: originalArchive)
        let artifact = try DiscordTestFixture.makeArtifact(in: root)
        let gate = PatchExecutionGate()
        let coordinator = DiscordInstallerCoordinator(
            downloadLatest: { artifact },
            applyPatch: { target, artifact, operation in
                gate.pause()
                try operation.admitCommit()
                try DiscordAppPatcher.install(target: target, artifact: artifact, operation: operation)
            }
        )

        let operation = Task { try await coordinator.install(target: target) }
        guard await gate.waitUntilStarted() else {
            gate.release()
            XCTFail("The detached patch operation did not start.")
            return
        }
        coordinator.cancelActiveOperation()
        gate.release()

        do {
            _ = try await operation.value
            XCTFail("A cancelled patch operation must not modify Discord.")
        } catch is CancellationError {
        }

        XCTAssertEqual(try Data(contentsOf: target.appArchiveURL), originalArchive)
        XCTAssertEqual(DiscordAppPatcher.state(for: target), .ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.fileURL.path))
    }

    func testCancellationAfterCommitAdmissionLetsPatchFinish() async throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let originalArchive = try EquicordAsarArchive.makeArchive(files: [
            "index.js": Data("module.exports = 'stock';".utf8)
        ])
        let target = try DiscordTestFixture.makeApplication(at: root, originalArchive: originalArchive)
        let artifact = try DiscordTestFixture.makeArtifact(in: root)
        let gate = PatchExecutionGate()
        let coordinator = DiscordInstallerCoordinator(
            downloadLatest: { artifact },
            applyPatch: { target, artifact, operation in
                try operation.admitCommit()
                gate.pause()
                try DiscordAppPatcher.install(target: target, artifact: artifact, operation: operation)
            }
        )

        let install = Task { try await coordinator.install(target: target) }
        guard await gate.waitUntilStarted() else {
            gate.release()
            XCTFail("The commit-admitted patch did not start.")
            return
        }
        coordinator.cancelActiveOperation()
        gate.release()

        let installedVersion = try await install.value
        XCTAssertEqual(installedVersion, artifact.version)
        XCTAssertEqual(DiscordAppPatcher.state(for: target), .installed)
        XCTAssertNotEqual(try Data(contentsOf: target.appArchiveURL), originalArchive)
    }

    func testRemovedCustomTargetBeforeRefreshStartsNoDownloadOrBuild() async throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try DiscordTestFixture.makeCustomApplication(at: root)
        var discovered = [target]
        let picker = DiscordTargetPickerView(discoverTargets: { discovered })

        try FileManager.default.removeItem(at: target.applicationURL)
        discovered = []
        picker.refresh()
        XCTAssertNil(picker.selectedTarget)

        let downloadCounter = DiscordOperationCounter()
        let commandCounter = DiscordOperationCounter()
        let artifact = try DiscordTestFixture.makeArtifact(in: root)
        let sourceBuilder = EquicordSourceBuilder(
            supportDirectory: root.appendingPathComponent("Application Support", isDirectory: true),
            tools: EquicordSourceTools(
                git: URL(fileURLWithPath: "/fake/git"),
                node: URL(fileURLWithPath: "/fake/node"),
                pnpm: URL(fileURLWithPath: "/fake/pnpm")
            ),
            runCommand: { _, _, _, _ in
                await commandCounter.increment()
                return 1
            }
        )
        let coordinator = DiscordInstallerCoordinator(
            downloadLatest: {
                await downloadCounter.increment()
                return artifact
            },
            sourceBuilder: sourceBuilder
        )

        do {
            _ = try await coordinator.install(target: target)
            XCTFail("A missing custom app must be rejected before download.")
        } catch DiscordAppPatcherError.applicationChanged {
        } catch {
            XCTFail("Unexpected install error: \(error)")
        }

        do {
            _ = try await coordinator.buildDevFromSource(target: target) { _ in }
            XCTFail("A missing custom app must be rejected before source build.")
        } catch DiscordAppPatcherError.applicationChanged {
        } catch {
            XCTFail("Unexpected source-build error: \(error)")
        }

        let downloads = await downloadCounter.count()
        let sourceCommands = await commandCounter.count()
        XCTAssertEqual(downloads, 0)
        XCTAssertEqual(sourceCommands, 0)
    }

}
