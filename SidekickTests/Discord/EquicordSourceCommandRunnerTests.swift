import Darwin
import Foundation
import XCTest

@MainActor
final class EquicordSourceCommandRunnerTests: XCTestCase {
    func testCancellationTerminatesDescendantsBeforeReturning() async throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let startedPipe = root.appendingPathComponent("child-started")
        let releasePipe = root.appendingPathComponent("child-release")
        let lateWrite = root.appendingPathComponent("child-late-write")
        XCTAssertEqual(mkfifo(startedPipe.path, mode_t(S_IRUSR | S_IWUSR)), 0)
        XCTAssertEqual(mkfifo(releasePipe.path, mode_t(S_IRUSR | S_IWUSR)), 0)

        let releaseDescriptor = open(releasePipe.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        guard releaseDescriptor >= 0 else {
            XCTFail("Could not keep the descendant release pipe open.")
            return
        }
        defer { close(releaseDescriptor) }

        let script = #"""
            /bin/sh -c 'printf "%s\n" "$$" > "$1"; IFS= read -r _ < "$2"; printf late > "$3"' child "$1" "$2" "$3" &
            wait
            """#
        let runner = EquicordSourceCommandRunner()
        let started = expectation(description: "descendant entered its blocking operation")
        let pidReader = Task.detached {
            let handle = try FileHandle(forReadingFrom: startedPipe)
            defer { try? handle.close() }
            let data = try handle.readToEnd() ?? Data()
            started.fulfill()
            guard let text = String(data: data, encoding: .utf8) else { throw POSIXError(.EILSEQ) }
            return text
        }
        let operation = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script, "runner", startedPipe.path, releasePipe.path, lateWrite.path],
                directory: root,
                operationGeneration: 1
            )
        }

        await fulfillment(of: [started], timeout: 5)
        let unblockReader = open(startedPipe.path, O_WRONLY | O_NONBLOCK)
        if unblockReader >= 0 { close(unblockReader) }
        let childPIDText = try await pidReader.value
        guard let childPID = pid_t(childPIDText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            _ = try? await operation.value
            XCTFail("The descendant did not report its process ID.")
            return
        }

        await runner.cancelCurrent(operationGeneration: 1)
        let childResult = kill(childPID, 0)
        let childError = errno
        XCTAssertEqual(childResult, -1)
        XCTAssertEqual(childError, ESRCH)
        let releaseMessage = "continue\n"
        _ = releaseMessage.withCString { write(releaseDescriptor, $0, releaseMessage.utf8.count) }
        _ = try await operation.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: lateWrite.path))
    }

    func testCancelledGenerationCannotSpawnAfterCancelWinsActorRace() async throws {
        let root = try DiscordTestFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("stale-command-ran")
        let runner = EquicordSourceCommandRunner()
        await runner.cancelCurrent(operationGeneration: 1)

        do {
            _ = try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf stale > \"$1\"", "runner", marker.path],
                directory: root,
                operationGeneration: 1
            )
            XCTFail("A command from a cancelled generation must not spawn.")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        let status = try await runner.run(
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            directory: root,
            operationGeneration: 2
        )
        XCTAssertEqual(status, 0)
    }
}
