import Foundation

enum DiscordInstallerCoordinatorError: LocalizedError {
    case temporaryDownloadCleanupFailed(path: String, operation: String)

    var errorDescription: String? {
        switch self {
        case .temporaryDownloadCleanupFailed(let path, let operation):
            "The temporary Equicord download remains at \(path). \(operation)"
        }
    }
}

@MainActor
final class DiscordInstallerCoordinator {
    typealias DownloadLatest = @Sendable () async throws -> EquicordReleaseArtifact
    typealias ApplyPatch = @Sendable (
        DiscordInstallTarget,
        EquicordReleaseArtifact,
        DiscordPatchOperation
    ) throws -> Void

    private struct ActivePatch {
        let generation: UInt64
        let operation: DiscordPatchOperation
        let task: Task<Void, Error>
    }

    private let downloadLatest: DownloadLatest
    private let applyPatch: ApplyPatch
    private let sourceBuilder: EquicordSourceBuilder
    private var operationGeneration: UInt64 = 0
    private var patchTask: ActivePatch?

    init(
        downloadLatest: @escaping DownloadLatest = {
            try await EquicordReleaseDownloader().downloadLatest()
        },
        applyPatch: @escaping ApplyPatch = { target, artifact, operation in
            try DiscordAppPatcher.install(target: target, artifact: artifact, operation: operation)
        },
        sourceBuilder: EquicordSourceBuilder = EquicordSourceBuilder()
    ) {
        self.downloadLatest = downloadLatest
        self.applyPatch = applyPatch
        self.sourceBuilder = sourceBuilder
    }

    var sourceDirectoryURL: URL { sourceBuilder.sourceDirectoryURL }
    var hasRetainedSource: Bool { sourceBuilder.hasSource }

    func install(target: DiscordInstallTarget) async throws -> String {
        return try await performInstall(
            target: target,
            progress: { _ in },
            createArtifact: { try await downloadLatest() }
        )
    }

    func buildDevFromSource(
        target: DiscordInstallTarget,
        progress: @escaping (String) -> Void
    ) async throws -> String {
        return try await performInstall(
            target: target,
            progress: progress,
            createArtifact: { try await sourceBuilder.build(progress: progress) }
        )
    }

    private func performInstall(
        target: DiscordInstallTarget,
        progress: @escaping (String) -> Void,
        createArtifact: () async throws -> EquicordReleaseArtifact
    ) async throws -> String {
        let generation = try await beginOperation()
        try Task.checkCancellation()
        guard generation == operationGeneration else { throw CancellationError() }
        guard let resolvedTarget = try? DiscordInstallTarget.resolve(target.applicationURL),
              resolvedTarget == target else {
            throw DiscordAppPatcherError.applicationChanged
        }

        let artifact: EquicordReleaseArtifact
        do {
            artifact = try await createArtifact()
        } catch {
            guard !Task.isCancelled, generation == operationGeneration else {
                throw CancellationError()
            }
            throw error
        }

        do {
            try Task.checkCancellation()
            guard generation == operationGeneration else { throw CancellationError() }
            progress("Installing Equicord into Discord…")
            let applyPatch = self.applyPatch
            try await runPatch(generation: generation) { operation in
                try applyPatch(target, artifact, operation)
            }
        } catch {
            try await removeTemporaryArtifact(
                artifact,
                operation: "The installation failed: \(error.localizedDescription)"
            )
            throw error
        }

        try await removeTemporaryArtifact(
            artifact,
            operation: "Equicord was installed, but temporary download cleanup failed."
        )
        return artifact.version
    }

    func repairBackupName(target: DiscordInstallTarget) async throws {
        let generation = try await beginOperation()
        try Task.checkCancellation()
        try await runPatch(generation: generation) { operation in
            try DiscordAppPatcher.repairBackupName(target: target, operation: operation)
        }
    }

    func uninstall(target: DiscordInstallTarget) async throws {
        let generation = try await beginOperation()
        try Task.checkCancellation()
        try await runPatch(generation: generation) { operation in
            try DiscordAppPatcher.uninstall(target: target, operation: operation)
        }
    }

    func cancelActiveOperation() {
        operationGeneration &+= 1
        if let patchTask, patchTask.operation.requestCancellation() {
            patchTask.task.cancel()
        }
        sourceBuilder.cancel()
    }

    private func beginOperation() async throws -> UInt64 {
        operationGeneration &+= 1
        let generation = operationGeneration
        if let currentPatch = patchTask {
            if currentPatch.operation.requestCancellation() {
                currentPatch.task.cancel()
            }
            _ = try? await currentPatch.task.value
            guard !Task.isCancelled, operationGeneration == generation else {
                throw CancellationError()
            }
            if patchTask?.generation == currentPatch.generation {
                patchTask = nil
            }
        }
        return generation
    }

    private func runPatch(
        generation: UInt64,
        operation: @escaping @Sendable (DiscordPatchOperation) throws -> Void
    ) async throws {
        guard !Task.isCancelled, operationGeneration == generation else {
            throw CancellationError()
        }
        let patchOperation = DiscordPatchOperation()
        let worker = Task.detached(priority: .userInitiated) {
            try operation(patchOperation)
        }
        patchTask = ActivePatch(generation: generation, operation: patchOperation, task: worker)
        do {
            try await worker.value
        } catch {
            if patchTask?.generation == generation {
                patchTask = nil
            }
            throw error
        }
        if patchTask?.generation == generation {
            patchTask = nil
        }
    }

    private func removeTemporaryArtifact(_ artifact: EquicordReleaseArtifact, operation: String) async throws {
        guard case .temporary = artifact.lifetime else { return }
        do {
            try await Task.detached(priority: .utility) {
                guard FileManager.default.fileExists(atPath: artifact.fileURL.path) else { return }
                try FileManager.default.removeItem(at: artifact.fileURL)
            }.value
        } catch {
            throw DiscordInstallerCoordinatorError.temporaryDownloadCleanupFailed(
                path: artifact.fileURL.path,
                operation: operation
            )
        }
    }
}
