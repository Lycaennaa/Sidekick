import Foundation
import XCTest

private actor FingerprintWaitGate {
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause(onStarted: @Sendable () -> Void) async {
        onStarted()
        guard !released else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
final class MacArtifactCleanupProcessorTests: XCTestCase {
    func testRemovingRootDuringFingerprintWaitPreservesCandidate() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-tmp/MacArtifactCleanupProcessorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent(".DS_Store")
        try Data([1, 2, 3]).write(to: candidate)
        let scannedMatches = try MacArtifactScanner.scan(root: root).matches
        XCTAssertEqual(scannedMatches.map(\.url.path), [candidate.path])

        let suiteName = "MacArtifactCleanupProcessorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MacArtifactCleanupStore(defaults: defaults)
        XCTAssertTrue(store.addFolder(root))
        store.setDefaultMode(.deletePermanently)
        let candidateScanned = expectation(description: "Candidate scan completed")
        let validationStarted = expectation(description: "Fingerprint validation started")

        let gate = FingerprintWaitGate()
        let processor = MacArtifactCleanupProcessor(
            store: store,
            notifier: MacArtifactCleanupNotifier(center: nil),
            quietPeriod: 0,
            fingerprintReader: { match in
                await gate.pause {
                    DispatchQueue.main.async { validationStarted.fulfill() }
                }
                return try MacArtifactScanner.fingerprint(for: match)
            }
        )
        processor.start(roots: store.configuration.roots)
        processor.onChange = { candidateScanned.fulfill() }
        await fulfillment(of: [candidateScanned], timeout: 5)
        processor.onChange = nil

        let cleanup = Task { @MainActor in await processor.processMatureCandidates() }
        await fulfillment(of: [validationStarted], timeout: 5)
        processor.updateRoots([])
        await gate.release()
        await cleanup.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        processor.stop()
        await processor.waitForBackgroundScans()
    }

    func testDefaultModeAutomaticallyDeletesDiscoveredArtifact() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-tmp/MacArtifactCleanupProcessorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let candidate = root.appendingPathComponent(".DS_Store")
        try Data([1, 2, 3]).write(to: candidate)

        let suiteName = "MacArtifactCleanupProcessorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MacArtifactCleanupStore(defaults: defaults)
        XCTAssertTrue(store.addFolder(root))

        let processor = MacArtifactCleanupProcessor(
            store: store,
            notifier: MacArtifactCleanupNotifier(center: nil),
            quietPeriod: 0
        )
        processor.start(roots: store.configuration.roots)
        await processor.waitForBackgroundScans()
        await processor.processMatureCandidates()

        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertEqual(store.history.first?.mode, .deletePermanently)
        XCTAssertEqual(store.history.first?.removedCount, 1)
        processor.stop()
        await processor.waitForBackgroundScans()
    }

    func testManualRemovalRequiresQuietPeriodAndCanUseRetainedPreviewCandidate() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-tmp/MacArtifactCleanupProcessorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let candidateURL = root.appendingPathComponent(".DS_Store")
        try Data([1, 2, 3]).write(to: candidateURL)
        let suiteName = "MacArtifactCleanupProcessorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MacArtifactCleanupStore(defaults: defaults)
        store.setDefaultMode(.previewOnly)
        XCTAssertTrue(store.addFolder(root))

        let processor = MacArtifactCleanupProcessor(
            store: store,
            notifier: MacArtifactCleanupNotifier(center: nil),
            quietPeriod: 0.3
        )
        processor.start(roots: store.configuration.roots)
        await processor.waitForBackgroundScans()
        let rootID = store.configuration.roots[0].id
        let preview = try await processor.preview(rootID: rootID)
        let match = try XCTUnwrap(preview.matches.first)

        let early = try XCTUnwrap(
            processor.applyManually([match], rootID: rootID, mode: .deletePermanently)
        )
        XCTAssertEqual(early.skippedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))

        try await Task.sleep(nanoseconds: 350_000_000)
        await processor.processMatureCandidates()
        XCTAssertEqual(store.history.first?.mode, .previewOnly)
        XCTAssertEqual(store.history.first?.skippedCount, 0, "\(store.history.first?.details ?? [])")
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
        let manualResult = processor.applyManually([match], rootID: rootID, mode: .deletePermanently)
        XCTAssertEqual(manualResult?.removedCount, 1)
        XCTAssertEqual(manualResult?.skippedCount, 0, "\(manualResult?.details ?? [])")
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidateURL.path))
        processor.stop()
        await processor.waitForBackgroundScans()
    }

    func testCompanionActivityResetsSidecarQuietPeriodAndStillScansCompanion() async throws {
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
        try Data([0, 5, 0x16, 7, 0, 0, 0, 2, 1]).write(to: sidecar)
        let suiteName = "MacArtifactCleanupProcessorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MacArtifactCleanupStore(defaults: defaults)
        store.setDefaultMode(.previewOnly)
        XCTAssertTrue(store.addFolder(root))

        let processor = MacArtifactCleanupProcessor(
            store: store,
            notifier: MacArtifactCleanupNotifier(center: nil),
            quietPeriod: 0.5
        )
        processor.start(roots: store.configuration.roots)
        await processor.waitForBackgroundScans()
        try await Task.sleep(nanoseconds: 250_000_000)

        try Data([1]).write(to: companion)
        processor.receive([MacArtifactFileEvent(path: companion.path, flags: 0)])
        await processor.waitForBackgroundScans()
        try await Task.sleep(nanoseconds: 300_000_000)
        await processor.processMatureCandidates()
        XCTAssertTrue(store.history.isEmpty)

        try await Task.sleep(nanoseconds: 250_000_000)
        await processor.processMatureCandidates()
        XCTAssertEqual(store.history.first?.matchedCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: companion.path))
        processor.stop()
        await processor.waitForBackgroundScans()
    }

    func testManualBatchRemovesAppleDoubleBeforeCompanion() async throws {
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
        store.setDefaultMode(.previewOnly)
        XCTAssertTrue(store.addFolder(root))

        let processor = MacArtifactCleanupProcessor(
            store: store,
            notifier: MacArtifactCleanupNotifier(center: nil),
            quietPeriod: 0
        )
        defer { processor.stop() }
        processor.start(roots: store.configuration.roots)
        await processor.waitForBackgroundScans()
        let rootID = store.configuration.roots[0].id
        let preview = try await processor.preview(rootID: rootID)
        XCTAssertEqual(preview.matches.map(\.kind), [.appleDoubleSidecar, .desktopDatabase])

        let result = processor.applyManually(
            preview.matches,
            rootID: rootID,
            mode: .deletePermanently
        )
        XCTAssertEqual(result?.removedCount, 2)
        XCTAssertEqual(result?.skippedCount, 0, "\(result?.details ?? [])")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: companion.path))
        processor.stop()
        await processor.waitForBackgroundScans()
    }
    func testManualPreviewRestartsQuietPeriodForUnreportedLeafReplacement() async throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-tmp/MacArtifactCleanupProcessorTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent(".DS_Store")
        try Data([1, 2, 3]).write(to: candidate)

        let suiteName = "MacArtifactCleanupProcessorTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MacArtifactCleanupStore(defaults: defaults)
        XCTAssertTrue(store.addFolder(root))
        store.setDefaultMode(.deletePermanently)
        let quietPeriod: TimeInterval = 0.2
        let processor = MacArtifactCleanupProcessor(
            store: store,
            notifier: MacArtifactCleanupNotifier(center: nil),
            quietPeriod: quietPeriod
        )
        defer { processor.stop() }
        processor.start(roots: store.configuration.roots)
        await processor.waitForBackgroundScans()
        processor.receive([MacArtifactFileEvent(path: candidate.path, flags: 0)])
        await processor.waitForBackgroundScans()
        try await Task.sleep(nanoseconds: 350_000_000)

        try Data([4, 5, 6, 7]).write(to: candidate, options: .atomic)
        let replacementMatches = try MacArtifactScanner.scan(root: root).matches
        XCTAssertEqual(replacementMatches.map(\.url.path), [candidate.path])
        let rootID = try XCTUnwrap(store.configuration.roots.first?.id)
        let attempt = processor.applyManually(
            replacementMatches,
            rootID: rootID,
            mode: .deletePermanently
        )
        XCTAssertEqual(attempt?.removedCount, 0)
        XCTAssertEqual(attempt?.skippedCount, 1, "\(attempt?.details ?? [])")
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        XCTAssertEqual(try Data(contentsOf: candidate), Data([4, 5, 6, 7]))

        processor.stop()
        await processor.waitForBackgroundScans()
    }
}
