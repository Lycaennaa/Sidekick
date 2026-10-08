import Darwin
import Foundation

actor EquicordSourceCommandRunner {
    private var activeProcessGroup: pid_t?
    private var activeRunID: UUID?
    private var activeOperationGeneration: UInt64?
    private var cancelledThroughGeneration: UInt64?

    func run(
        executable: URL,
        arguments: [String],
        directory: URL,
        operationGeneration: UInt64
    ) async throws -> Int32 {
        try Task.checkCancellation()
        if let cancelledThroughGeneration, operationGeneration <= cancelledThroughGeneration {
            throw CancellationError()
        }
        let processGroup = try Self.spawn(executable: executable, arguments: arguments, directory: directory)
        let runID = UUID()
        activeProcessGroup = processGroup
        activeRunID = runID
        activeOperationGeneration = operationGeneration

        let status: Int32
        do {
            status = try await Task.detached(priority: .utility) {
                try Self.waitForProcess(processGroup)
            }.value
        } catch {
            await Task.detached(priority: .utility) {
                Self.terminateProcessGroup(processGroup)
            }.value
            guard activeRunID == runID,
                  activeProcessGroup == processGroup,
                  activeOperationGeneration == operationGeneration else {
                throw CancellationError()
            }
            activeProcessGroup = nil
            activeRunID = nil
            activeOperationGeneration = nil
            throw error
        }

        if Self.processGroupExists(processGroup) {
            await Task.detached(priority: .utility) {
                Self.terminateProcessGroup(processGroup)
            }.value
        }
        guard activeRunID == runID,
              activeProcessGroup == processGroup,
              activeOperationGeneration == operationGeneration else {
            throw CancellationError()
        }
        activeProcessGroup = nil
        activeRunID = nil
        activeOperationGeneration = nil
        return status
    }

    func cancelCurrent(operationGeneration: UInt64) {
        if cancelledThroughGeneration.map({ operationGeneration > $0 }) ?? true {
            cancelledThroughGeneration = operationGeneration
        }
        guard activeOperationGeneration == operationGeneration,
              let activeProcessGroup else {
            return
        }
        Self.terminateProcessGroup(activeProcessGroup)
    }

    private nonisolated static func spawn(executable: URL, arguments: [String], directory: URL) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        let actionsResult = posix_spawn_file_actions_init(&actions)
        guard actionsResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: actionsResult) ?? .EIO)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }

        let directoryResult = directory.path.withCString {
            posix_spawn_file_actions_addchdir_np(&actions, $0)
        }
        let outputResult = "/dev/null".withCString {
            posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, $0, O_WRONLY, 0)
        }
        let errorResult = "/dev/null".withCString {
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, $0, O_WRONLY, 0)
        }
        guard directoryResult == 0, outputResult == 0, errorResult == 0 else {
            let code = [directoryResult, outputResult, errorResult].first { $0 != 0 } ?? EIO
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        var attributes: posix_spawnattr_t?
        let attributesResult = posix_spawnattr_init(&attributes)
        guard attributesResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: attributesResult) ?? .EIO)
        }
        defer { posix_spawnattr_destroy(&attributes) }
        let groupResult = posix_spawnattr_setpgroup(&attributes, 0)
        let flagsResult = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        guard groupResult == 0, flagsResult == 0 else {
            let code = groupResult != 0 ? groupResult : flagsResult
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }

        let argumentPointers = try makeCStringPointers([executable.path] + arguments)
        defer { freeCStringPointers(argumentPointers) }
        let environment = ProcessInfo.processInfo.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let environmentPointers = try makeCStringPointers(environment)
        defer { freeCStringPointers(environmentPointers) }

        var processID: pid_t = 0
        let spawnResult = argumentPointers.withUnsafeBufferPointer { argv in
            environmentPointers.withUnsafeBufferPointer { envp in
                executable.path.withCString {
                    posix_spawn(&processID, $0, &actions, &attributes, argv.baseAddress, envp.baseAddress)
                }
            }
        }
        guard spawnResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: spawnResult) ?? .EIO)
        }
        return processID
    }

    private nonisolated static func makeCStringPointers(_ values: [String]) throws -> [UnsafeMutablePointer<CChar>?] {
        var pointers: [UnsafeMutablePointer<CChar>?] = []
        for value in values {
            guard let pointer = strdup(value) else {
                freeCStringPointers(pointers)
                throw POSIXError(.ENOMEM)
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
        return pointers
    }

    private nonisolated static func freeCStringPointers(_ pointers: [UnsafeMutablePointer<CChar>?]) {
        for pointer in pointers {
            if let pointer { free(pointer) }
        }
    }

    private nonisolated static func waitForProcess(_ processID: pid_t) throws -> Int32 {
        var waitStatus: Int32 = 0
        while true {
            let result = waitpid(processID, &waitStatus, 0)
            if result == processID {
                return (waitStatus & 0x7f) == 0 ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
            }
            if result == -1, errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private nonisolated static func processGroupExists(_ processGroup: pid_t) -> Bool {
        if kill(-processGroup, 0) == 0 { return true }
        return errno == EPERM
    }

    // Keep inherited descendants from overlapping the next source-build command.
    private nonisolated static func terminateProcessGroup(_ processGroup: pid_t) {
        guard processGroupExists(processGroup) else { return }
        _ = kill(-processGroup, SIGTERM)
        let graceDeadline = DispatchTime.now() + .milliseconds(500)
        while processGroupExists(processGroup), DispatchTime.now() < graceDeadline {
            usleep(10_000)
        }
        if processGroupExists(processGroup) {
            _ = kill(-processGroup, SIGKILL)
        }
        while processGroupExists(processGroup) {
            usleep(10_000)
        }
    }
}
