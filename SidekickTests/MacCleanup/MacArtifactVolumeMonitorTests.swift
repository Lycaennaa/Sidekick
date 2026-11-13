import AppKit
import Darwin
import Foundation
import XCTest

@MainActor
final class MacArtifactVolumeMonitorTests: XCTestCase {
    func testMountedDiskImageIsNotEligibleForAutomaticOrFolderCleanup() async throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-tmp/MacArtifactVolumeMonitorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let image = directory.appendingPathComponent("volume.sparseimage")
        let volumeName = "SidekickCleanup-\(UUID().uuidString.prefix(8))"
        let volumeURL = URL(fileURLWithPath: "/Volumes/\(volumeName)", isDirectory: true)
        let selectedFolder = volumeURL.appendingPathComponent("Selected", isDirectory: true)
        try runHdiutil([
            "create", "-quiet", "-size", "32m", "-fs", "HFS+",
            "-volname", volumeName,
            "-type", "SPARSE", "-o", image.path
        ])

        let suiteName = "MacArtifactVolumeMonitorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MacArtifactCleanupStore(defaults: defaults)
        let coordinator = MacArtifactCleanupCoordinator(store: store)
        let imageEnrollmentRequested = expectation(description: "Disk image enrollment is not requested")
        imageEnrollmentRequested.isInverted = true
        coordinator.onRequestEnrollment = { volume in
            if volume.url.standardizedFileURL.path == volumeURL.standardizedFileURL.path {
                imageEnrollmentRequested.fulfill()
            }
        }
        coordinator.start()
        var isMounted = false
        defer {
            coordinator.stop()
            if isMounted {
                try? runHdiutil(["detach", "-quiet", "-force", volumeURL.path])
            }
        }

        try await runHdiutilDetached(["attach", "-quiet", "-nobrowse", image.path])
        isMounted = true
        try FileManager.default.createDirectory(at: selectedFolder, withIntermediateDirectories: true)

        XCTAssertFalse(
            MacArtifactVolumeMonitor().mountedExternalVolumes().contains {
                $0.url.standardizedFileURL.path == volumeURL.standardizedFileURL.path
            }
        )
        let addedSelectedFolder = await store.addFolder(selectedFolder)
        XCTAssertFalse(addedSelectedFolder)
        XCTAssertTrue(store.configuration.roots.isEmpty)
        await fulfillment(of: [imageEnrollmentRequested], timeout: 1)
        coordinator.stop()
        try await assertPreviouslyEnrolledDiskImageRootIsInactive(
            at: selectedFolder,
            defaults: defaults
        )

        try await runHdiutilDetached(["detach", "-quiet", "-force", volumeURL.path])
        isMounted = false
    }

    func testAutomaticBatchProcessesAppleDoubleBeforeCompanion() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-tmp/MacArtifactCleanupProcessorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sidecar = root.appendingPathComponent("._.DS_Store")
        let companion = root.appendingPathComponent(".DS_Store")
        try Data([0, 5, 0x16, 7, 0, 0, 0, 2]).write(to: sidecar)
        try Data([1, 2, 3]).write(to: companion)

        let defaultsName = "MacArtifactCleanupProcessorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = makeSupportedFolderCleanupTestStore(defaults: defaults)
        store.setDefaultMode(.deletePermanently)
        let addedRoot = await store.addFolder(root)
        XCTAssertTrue(addedRoot)
        let processor = MacArtifactCleanupProcessor(
            store: store,
            notifier: MacArtifactCleanupNotifier(center: nil),
            quietPeriod: 0
        )
        defer { processor.stop() }
        processor.start(roots: store.configuration.roots)
        await processor.waitForBackgroundScans()

        let scan = try MacArtifactScanner.scan(root: root)
        XCTAssertEqual(scan.matches.map(\.kind), [.appleDoubleSidecar, .desktopDatabase])
        await processor.processMatureCandidates()
        let result = try XCTUnwrap(store.history.first)
        XCTAssertEqual(result.removedCount, 2)
        XCTAssertEqual(result.skippedCount, 0, "\(result.details)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: companion.path))
        await processor.waitForBackgroundScans()
    }
    func testManualFailureRemainsManualOnlyAcrossCompanionRemovalAndFingerprintRefresh() async throws {
        let directory = try Self.makeTemporaryDirectory(named: "MacArtifactManualRetryTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("Selected", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sidecar = root.appendingPathComponent("._.DS_Store")
        let companion = root.appendingPathComponent(".DS_Store")
        try Data([0, 5, 0x16, 7, 0, 0, 0, 2]).write(to: sidecar)
        try Data([1, 2, 3]).write(to: companion)
        let flagResult = sidecar.path.withCString { chflags($0, UInt32(UF_IMMUTABLE)) }
        XCTAssertEqual(flagResult, 0)
        defer { _ = sidecar.path.withCString { chflags($0, 0) } }

        let defaultsName = "MacArtifactManualRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = makeSupportedFolderCleanupTestStore(defaults: defaults)
        store.setDefaultMode(.previewOnly)
        let addedRoot = await store.addFolder(root)
        XCTAssertTrue(addedRoot)
        let processor = MacArtifactCleanupProcessor(
            store: store,
            notifier: MacArtifactCleanupNotifier(center: nil),
            quietPeriod: 0
        )
        defer { processor.stop() }
        processor.start(roots: store.configuration.roots)
        await processor.waitForBackgroundScans()
        await processor.processMatureCandidates()
        let rootID = store.configuration.roots[0].id
        let preview = try await processor.preview(rootID: rootID)
        XCTAssertEqual(preview.matches.map(\.kind), [.appleDoubleSidecar, .desktopDatabase])

        let failedAttempt = processor.applyManually(preview.matches, rootID: rootID, mode: .deletePermanently)
        XCTAssertEqual(failedAttempt?.removedCount, 1, "\(failedAttempt?.details ?? [])")
        XCTAssertEqual(failedAttempt?.skippedCount, 1, "\(failedAttempt?.details ?? [])")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: companion.path))
        XCTAssertEqual(try Data(contentsOf: sidecar), Data([0, 5, 0x16, 7, 0, 0, 0, 2]))

        let unobservedScan = try MacArtifactScanner.scan(root: root)
        XCTAssertEqual(unobservedScan.matches.map(\.kind), [.appleDoubleSidecar])
        let unobservedAttempt = processor.applyManually(
            unobservedScan.matches,
            rootID: rootID,
            mode: .deletePermanently
        )
        XCTAssertEqual(unobservedAttempt?.removedCount, 0, "\(unobservedAttempt?.details ?? [])")
        XCTAssertEqual(unobservedAttempt?.skippedCount, 1, "\(unobservedAttempt?.details ?? [])")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        store.setDefaultMode(.deletePermanently)
        XCTAssertEqual(sidecar.path.withCString { chflags($0, 0) }, 0)
        processor.receive([MacArtifactFileEvent(path: companion.path, flags: 0)])
        await processor.waitForBackgroundScans()
        await processor.processMatureCandidates()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: companion.path))

        let retryPreview = try await processor.preview(rootID: rootID)
        XCTAssertEqual(retryPreview.matches.map(\.kind), [.appleDoubleSidecar])
        let retry = processor.applyManually(retryPreview.matches, rootID: rootID, mode: .deletePermanently)
        XCTAssertEqual(retry?.removedCount, 1, "\(retry?.details ?? [])")
        XCTAssertEqual(retry?.skippedCount, 0, "\(retry?.details ?? [])")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        await processor.waitForBackgroundScans()
    }
    func testTrashAndSymlinkBoundaryOnMountedVolume() async throws {
        let directory = try Self.makeTemporaryDirectory(named: "MacArtifactTrashBoundaryTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("trash.sparseimage")
        let volumeName = "SidekickTrash-\(UUID().uuidString.prefix(8))"
        let volumeURL = URL(fileURLWithPath: "/Volumes/\(volumeName)", isDirectory: true)
        try Self.createDiskImage(at: image, volumeName: volumeName)
        var isMounted = false
        defer {
            if isMounted {
                try? runHdiutil(["detach", "-quiet", "-force", volumeURL.path])
            }
        }
        try await runHdiutilDetached(["attach", "-quiet", "-nobrowse", image.path])
        isMounted = true
        try prepareTrashDirectory(on: volumeURL)

        let selectedRoot = volumeURL.appendingPathComponent("Selected", isDirectory: true)
        let outside = volumeURL.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try verifyFileTrash(at: selectedRoot, outside: outside)
        try verifyMetadataDirectoryTrash(at: selectedRoot)
        try verifySymlinkBoundary(at: selectedRoot, outside: outside)
    }

    private func prepareTrashDirectory(on volumeURL: URL) throws {
        let volumeTrash = volumeURL.appendingPathComponent(".Trashes", isDirectory: true)
        try FileManager.default.createDirectory(at: volumeTrash, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o1777], ofItemAtPath: volumeTrash.path)
    }

    private func verifyFileTrash(at selectedRoot: URL, outside: URL) throws {
        let candidate = selectedRoot.appendingPathComponent(".DS_Store")
        try Data([1, 2, 3]).write(to: candidate)
        let match = try XCTUnwrap(MacArtifactScanner.scan(root: selectedRoot).matches.first)
        XCTAssertThrowsError(
            try MacArtifactSafeFileSystem.moveToTrash(
                match,
                beforeMovedEntryValidation: { _ in
                    throw NSError(domain: "MacArtifactSafeTrashTests", code: 1)
                }
            )
        )
        XCTAssertEqual(try Data(contentsOf: candidate), Data([1, 2, 3]))
        try assertTrashDestinationReplacementIsNotRestored(
            match: match,
            candidate: candidate,
            displacedOriginal: outside.appendingPathComponent("DisplacedOriginal")
        )

        let successfulMatch = try XCTUnwrap(MacArtifactScanner.scan(root: selectedRoot).matches.first)
        let result = MacArtifactCleaner.apply(successfulMatch, mode: .moveToTrash)
        guard case .movedToTrash(let trashURL) = result else {
            XCTFail("The default cleaner did not move a real volume artifact to Trash: \(result).")
            return
        }
        defer { try? FileManager.default.removeItem(at: trashURL) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.path))
    }

    private func verifyMetadataDirectoryTrash(at selectedRoot: URL) throws {
        let metadataDirectory = selectedRoot.appendingPathComponent("__MACOSX", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try Data([7, 8, 9]).write(to: metadataDirectory.appendingPathComponent(".DS_Store"))
        let metadataMatch = try XCTUnwrap(
            MacArtifactScanner.scan(root: selectedRoot).matches.first { $0.url.path == metadataDirectory.path }
        )
        guard case .movedToTrash(let trashURL) = MacArtifactCleaner.apply(metadataMatch, mode: .moveToTrash) else {
            XCTFail("The default cleaner did not move a metadata directory to Trash.")
            return
        }
        defer { try? FileManager.default.removeItem(at: trashURL) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.path))
    }

    private func verifySymlinkBoundary(at selectedRoot: URL, outside: URL) throws {
        let selectedDirectory = selectedRoot.appendingPathComponent("Nested", isDirectory: true)
        let relocatedDirectory = outside.appendingPathComponent("Relocated", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedDirectory, withIntermediateDirectories: true)
        let candidate = selectedDirectory.appendingPathComponent(".DS_Store")
        let sentinel = outside.appendingPathComponent(".DS_Store")
        try Data([4, 5, 6]).write(to: candidate)
        try Data([9, 8, 7]).write(to: sentinel)
        let match = try XCTUnwrap(
            MacArtifactScanner.scan(root: selectedRoot).matches.first { $0.url.path == candidate.path }
        )
        let trashURL = try MacArtifactSafeFileSystem.moveToTrash(
            match,
            beforeMutation: {
                try FileManager.default.moveItem(at: selectedDirectory, to: relocatedDirectory)
                try FileManager.default.createSymbolicLink(
                    at: selectedDirectory,
                    withDestinationURL: outside
                )
            }
        )
        XCTAssertNil(trashURL)
        let relocatedCandidate = relocatedDirectory.appendingPathComponent(".DS_Store")
        XCTAssertTrue(FileManager.default.fileExists(atPath: relocatedCandidate.path))
        XCTAssertEqual(try Data(contentsOf: relocatedCandidate), Data([4, 5, 6]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([9, 8, 7]))
    }

    private func assertTrashDestinationReplacementIsNotRestored(
        match: MacArtifactMatch,
        candidate: URL,
        displacedOriginal: URL
    ) throws {
        var attemptedTrashURL: URL?
        defer {
            if let attemptedTrashURL {
                try? FileManager.default.removeItem(at: attemptedTrashURL)
            }
            if FileManager.default.fileExists(atPath: displacedOriginal.path),
               !FileManager.default.fileExists(atPath: candidate.path) {
                try? FileManager.default.moveItem(at: displacedOriginal, to: candidate)
            }
        }

        let sourceRaceResult = try MacArtifactSafeFileSystem.moveToTrash(
            match,
            beforeMutation: {
                try FileManager.default.moveItem(at: candidate, to: displacedOriginal)
                try Data([4, 5, 6]).write(to: candidate)
            }
        )
        XCTAssertNil(sourceRaceResult)
        XCTAssertEqual(try Data(contentsOf: displacedOriginal), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: candidate), Data([4, 5, 6]))
        try FileManager.default.removeItem(at: candidate)
        try FileManager.default.moveItem(at: displacedOriginal, to: candidate)
        let refreshedMatch = try XCTUnwrap(
            MacArtifactScanner.scan(root: candidate.deletingLastPathComponent()).matches.first
        )
        XCTAssertThrowsError(
            try MacArtifactSafeFileSystem.moveToTrash(
                refreshedMatch,
                beforeMovedEntryValidation: { destinationURL in
                    attemptedTrashURL = destinationURL
                    try FileManager.default.moveItem(at: destinationURL, to: displacedOriginal)
                    try Data([4, 5, 6]).write(to: destinationURL)
                }
            )
        )
        let destinationURL = try XCTUnwrap(attemptedTrashURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertEqual(try Data(contentsOf: displacedOriginal), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: destinationURL), Data([4, 5, 6]))
    }
    private nonisolated static func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-tmp/\(name)", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private nonisolated static func createDiskImage(at image: URL, volumeName: String) throws {
        try runHdiutil([
            "create", "-quiet", "-size", "32m", "-fs", "HFS+",
            "-volname", volumeName,
            "-type", "SPARSE", "-o", image.path
        ])
    }
}
private func runHdiutilDetached(_ arguments: [String]) async throws {
    // hdiutil blocks; keep it off XCTest's actor and await before updating mount state.
    let operation = Task.detached {
        try Task.checkCancellation()
        try runHdiutil(arguments)
    }
    try await withTaskCancellationHandler {
        try await operation.value
    } onCancel: {
        operation.cancel()
    }
}

private func runHdiutil(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let details = String(data: data, encoding: .utf8) ?? "hdiutil failed."
        throw NSError(
            domain: "MacArtifactVolumeMonitorTests",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: details]
        )
    }
}
@MainActor
private func assertPreviouslyEnrolledDiskImageRootIsInactive(
    at folder: URL,
    defaults: UserDefaults
) async throws {
    let imageIdentifier = try XCTUnwrap(
        MacArtifactCleanupRoot.currentVolumeIdentifier(at: folder)
    )
    let legacyRoot = MacArtifactCleanupRoot(
        id: UUID(),
        path: folder.path,
        kind: .folder,
        volumeIdentifier: imageIdentifier,
        modeOverride: nil
    )
    let legacyConfiguration = MacArtifactCleanupConfiguration(
        defaultMode: .deletePermanently,
        roots: [legacyRoot]
    )
    defaults.set(
        try JSONEncoder().encode(legacyConfiguration),
        forKey: "macArtifactCleanupConfiguration"
    )
    let store = MacArtifactCleanupStore(defaults: defaults)
    let coordinator = MacArtifactCleanupCoordinator(store: store)
    let candidate = folder.appendingPathComponent(".DS_Store")
    try Data([1, 2, 3]).write(to: candidate)
    coordinator.start()
    defer { coordinator.stop() }

    do {
        _ = try await coordinator.preview(rootID: legacyRoot.id)
        XCTFail("A previously enrolled disk-image folder must remain inactive.")
    } catch is CancellationError {
        // Expected: mounted disk images are not eligible cleanup roots.
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
}
