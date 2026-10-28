import AppKit
import Darwin
import Foundation
import XCTest

@MainActor
final class MacArtifactVolumeMonitorTests: XCTestCase {
    func testMonitorObservesMountedEjectableDiskImage() async throws {
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
        try Self.runHdiutil([
            "create", "-quiet", "-size", "32m", "-fs", "HFS+",
            "-volname", volumeName,
            "-type", "SPARSE", "-o", image.path
        ])

        let monitor = MacArtifactVolumeMonitor()
        let didMount = expectation(description: "Mounted ejectable volume was observed")
        monitor.onMount = { volume in
            if volume.url.path == volumeURL.path { didMount.fulfill() }
        }
        monitor.start()
        var isMounted = false
        defer {
            monitor.stop()
            if isMounted {
                try? Self.runHdiutil(["detach", "-quiet", "-force", volumeURL.path])
            }
        }

        try await Task.detached {
            try Self.runHdiutil(["attach", "-quiet", "-nobrowse", image.path])
        }.value
        isMounted = true
        let volume = try XCTUnwrap(
            monitor.mountedExternalVolumes().first { $0.url.path == volumeURL.path }
        )
        XCTAssertFalse(volume.identifier.isEmpty)
        XCTAssertTrue(monitor.mountedExternalVolumes().allSatisfy {
            !$0.url.path.hasPrefix("/private/var/run/com.apple.security.cryptexd/mnt/")
        })
        XCTAssertTrue(
            monitor.mountedExternalVolumes().allSatisfy {
                !$0.url.path.hasPrefix("/private/var/run/com.apple.security.cryptexd/mnt/")
            },
            "System cryptex mounts must not prompt for enrollment."
        )

        await fulfillment(of: [didMount], timeout: 10)
        monitor.stop()
        try await Task.detached {
            try Self.runHdiutil(["detach", "-quiet", "-force", volumeURL.path])
        }.value
        isMounted = false
    }

    func testFolderRootDoesNotReactivateWhenReplacementVolumeUsesSamePath() async throws {
        let directory = try Self.makeTemporaryDirectory(named: "MacArtifactCleanupCoordinatorTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let mountPoint = directory.appendingPathComponent("mounted-volume", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        let originalImage = directory.appendingPathComponent("original.sparseimage")
        let replacementImage = directory.appendingPathComponent("replacement.sparseimage")
        let originalName = "SidekickOriginal-\(UUID().uuidString.prefix(8))"
        let replacementName = "SidekickReplacement-\(UUID().uuidString.prefix(8))"
        let defaultsName = "MacArtifactCleanupCoordinatorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }

        var isMounted = false
        var coordinator: MacArtifactCleanupCoordinator?
        defer {
            coordinator?.stop()
            if isMounted {
                try? Self.runHdiutil(["detach", "-quiet", "-force", mountPoint.path])
            }
        }

        try Self.createDiskImage(at: originalImage, volumeName: originalName)
        try Self.createDiskImage(at: replacementImage, volumeName: replacementName)
        try Self.runHdiutil([
            "attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path, originalImage.path
        ])
        isMounted = true

        let store = MacArtifactCleanupStore(defaults: defaults)
        XCTAssertTrue(store.addFolder(mountPoint))
        let folderRoot = try XCTUnwrap(store.configuration.roots.first)
        let originalIdentifier = try XCTUnwrap(folderRoot.volumeIdentifier)

        try Self.runHdiutil(["detach", "-quiet", "-force", mountPoint.path])
        isMounted = false
        try Self.runHdiutil([
            "attach", "-quiet", "-nobrowse", "-mountpoint", mountPoint.path, replacementImage.path
        ])
        isMounted = true

        let replacementIdentifier = try XCTUnwrap(
            MacArtifactCleanupRoot.currentVolumeIdentifier(at: mountPoint)
        )
        XCTAssertNotEqual(replacementIdentifier, originalIdentifier)
        let candidate = mountPoint.appendingPathComponent(".DS_Store")
        try Data([1, 2, 3]).write(to: candidate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        store.setDefaultMode(.deletePermanently)
        let cleanupCoordinator = MacArtifactCleanupCoordinator(store: store)
        coordinator = cleanupCoordinator
        var replacementWasPrompted = false
        cleanupCoordinator.onRequestEnrollment = { volume in
            if volume.identifier == replacementIdentifier { replacementWasPrompted = true }
        }
        cleanupCoordinator.start()
        XCTAssertTrue(replacementWasPrompted)

        do {
            _ = try await cleanupCoordinator.preview(rootID: folderRoot.id)
            XCTFail("Declining the replacement volume must leave the old folder root inactive.")
        } catch is CancellationError {
            // Expected: the old volume identity is no longer mounted at this path.
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
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
        let store = MacArtifactCleanupStore(defaults: defaults)
        store.setDefaultMode(.deletePermanently)
        XCTAssertTrue(store.addFolder(root))
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
    func testManualTrashFailureRemainsManualOnlyAcrossCompanionRemovalAndFingerprintRefresh() async throws {
        let directory = try Self.makeTemporaryDirectory(named: "MacArtifactManualTrashRetryTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("retry.sparseimage")
        let volumeName = "SidekickRetry-\(UUID().uuidString.prefix(8))"
        let volumeURL = URL(fileURLWithPath: "/Volumes/\(volumeName)", isDirectory: true)
        try Self.createDiskImage(at: image, volumeName: volumeName)
        var isMounted = false
        defer {
            if isMounted {
                try? Self.runHdiutil(["detach", "-quiet", "-force", volumeURL.path])
            }
        }
        try await Task.detached {
            try Self.runHdiutil(["attach", "-quiet", "-nobrowse", image.path])
        }.value
        isMounted = true

        let volumeTrash = volumeURL.appendingPathComponent(".Trashes", isDirectory: true)
        let userTrash = volumeTrash.appendingPathComponent(String(getuid()), isDirectory: true)
        try FileManager.default.createDirectory(at: userTrash, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o1777], ofItemAtPath: volumeTrash.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: userTrash.path)
        let collisionNames = (0..<1_000).map { suffix in
            suffix == 0 ? "._.DS_Store" : "._.DS_Store \(suffix)"
        }
        for name in collisionNames {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: userTrash.appendingPathComponent(name).path,
                contents: Data([0])
            ))
        }

        let root = volumeURL.appendingPathComponent("Selected", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sidecar = root.appendingPathComponent("._.DS_Store")
        let companion = root.appendingPathComponent(".DS_Store")
        try Data([0, 5, 0x16, 7, 0, 0, 0, 2]).write(to: sidecar)
        try Data([1, 2, 3]).write(to: companion)

        let defaultsName = "MacArtifactManualTrashRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = MacArtifactCleanupStore(defaults: defaults)
        store.setDefaultMode(.previewOnly)
        XCTAssertTrue(store.addFolder(root))
        let processor = MacArtifactCleanupProcessor(
            store: store,
            notifier: MacArtifactCleanupNotifier(center: nil),
            quietPeriod: 0.2
        )
        defer { processor.stop() }
        processor.start(roots: store.configuration.roots)
        await processor.waitForBackgroundScans()
        try await Task.sleep(nanoseconds: 350_000_000)
        let rootID = store.configuration.roots[0].id
        let preview = try await processor.preview(rootID: rootID)
        XCTAssertEqual(preview.matches.map(\.kind), [.appleDoubleSidecar, .desktopDatabase])

        let failedAttempt = processor.applyManually(preview.matches, rootID: rootID, mode: .moveToTrash)
        XCTAssertEqual(failedAttempt?.removedCount, 1, "\(failedAttempt?.details ?? [])")
        XCTAssertEqual(failedAttempt?.skippedCount, 1, "\(failedAttempt?.details ?? [])")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: companion.path))
        XCTAssertEqual(try Data(contentsOf: sidecar), Data([0, 5, 0x16, 7, 0, 0, 0, 2]))

        for name in collisionNames {
            try FileManager.default.removeItem(at: userTrash.appendingPathComponent(name))
        }
        let unobservedScan = try MacArtifactScanner.scan(root: root)
        XCTAssertEqual(unobservedScan.matches.map(\.kind), [.appleDoubleSidecar])
        let unobservedAttempt = processor.applyManually(
            unobservedScan.matches,
            rootID: rootID,
            mode: .moveToTrash
        )
        XCTAssertEqual(unobservedAttempt?.removedCount, 0, "\(unobservedAttempt?.details ?? [])")
        XCTAssertEqual(unobservedAttempt?.skippedCount, 1, "\(unobservedAttempt?.details ?? [])")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        store.setDefaultMode(.deletePermanently)
        processor.receive([MacArtifactFileEvent(path: companion.path, flags: 0)])
        await processor.waitForBackgroundScans()
        try await Task.sleep(nanoseconds: 350_000_000)
        await processor.processMatureCandidates()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: companion.path))

        let retryPreview = try await processor.preview(rootID: rootID)
        XCTAssertEqual(retryPreview.matches.map(\.kind), [.appleDoubleSidecar])
        let retry = processor.applyManually(retryPreview.matches, rootID: rootID, mode: .moveToTrash)
        XCTAssertEqual(retry?.removedCount, 1, "\(retry?.details ?? [])")
        XCTAssertEqual(retry?.skippedCount, 0, "\(retry?.details ?? [])")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        try FileManager.default.removeItem(at: volumeTrash)
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
                try? Self.runHdiutil(["detach", "-quiet", "-force", volumeURL.path])
            }
        }
        try await Task.detached {
            try Self.runHdiutil(["attach", "-quiet", "-nobrowse", image.path])
        }.value
        isMounted = true
        let volumeTrash = volumeURL.appendingPathComponent(".Trashes", isDirectory: true)
        try FileManager.default.createDirectory(at: volumeTrash, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o1777], ofItemAtPath: volumeTrash.path)

        let selectedRoot = volumeURL.appendingPathComponent("Selected", isDirectory: true)
        let outside = volumeURL.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let firstCandidate = selectedRoot.appendingPathComponent(".DS_Store")
        try Data([1, 2, 3]).write(to: firstCandidate)
        let firstMatch = try XCTUnwrap(MacArtifactScanner.scan(root: selectedRoot).matches.first)
        XCTAssertThrowsError(
            try MacArtifactSafeFileSystem.moveToTrash(
                firstMatch,
                beforeMovedEntryValidation: { _ in
                    throw NSError(domain: "MacArtifactSafeTrashTests", code: 1)
                }
            )
        )
        XCTAssertEqual(try Data(contentsOf: firstCandidate), Data([1, 2, 3]))
        try assertTrashDestinationReplacementIsNotRestored(
            match: firstMatch,
            candidate: firstCandidate,
            displacedOriginal: outside.appendingPathComponent("DisplacedOriginal")
        )
        let successfulMatch = try XCTUnwrap(
            MacArtifactScanner.scan(root: selectedRoot).matches.first
        )
        let result = MacArtifactCleaner.apply(successfulMatch, mode: .moveToTrash)
        guard case .movedToTrash(let firstTrashURL) = result else {
            XCTFail("The default cleaner did not move a real volume artifact to Trash: \(result).")
            return
        }
        defer { try? FileManager.default.removeItem(at: firstTrashURL) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstCandidate.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstTrashURL.path))

        let metadataDirectory = selectedRoot.appendingPathComponent("__MACOSX", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try Data([7, 8, 9]).write(to: metadataDirectory.appendingPathComponent(".DS_Store"))
        let metadataMatch = try XCTUnwrap(
            MacArtifactScanner.scan(root: selectedRoot).matches.first { $0.url.path == metadataDirectory.path }
        )
        guard case .movedToTrash(let metadataTrashURL) = MacArtifactCleaner.apply(
            metadataMatch,
            mode: .moveToTrash
        ) else {
            XCTFail("The default cleaner did not move a metadata directory to Trash.")
            return
        }
        defer { try? FileManager.default.removeItem(at: metadataTrashURL) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataTrashURL.path))

        let selectedDirectory = selectedRoot.appendingPathComponent("Nested", isDirectory: true)
        let relocatedDirectory = outside.appendingPathComponent("Relocated", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedDirectory, withIntermediateDirectories: true)
        let nestedCandidate = selectedDirectory.appendingPathComponent(".DS_Store")
        let sentinel = outside.appendingPathComponent(".DS_Store")
        try Data([4, 5, 6]).write(to: nestedCandidate)
        try Data([9, 8, 7]).write(to: sentinel)
        let nestedMatch = try XCTUnwrap(
            MacArtifactScanner.scan(root: selectedRoot).matches.first { $0.url.path == nestedCandidate.path }
        )
        let nestedTrashURL = try MacArtifactSafeFileSystem.moveToTrash(
            nestedMatch,
            beforeMutation: {
                try FileManager.default.moveItem(at: selectedDirectory, to: relocatedDirectory)
                try FileManager.default.createSymbolicLink(at: selectedDirectory, withDestinationURL: outside)
            }
        )
        XCTAssertNil(nestedTrashURL)
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
    private nonisolated static func runHdiutil(_ arguments: [String]) throws {
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
}
