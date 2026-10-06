import AppKit
import UniformTypeIdentifiers
import XCTest
@MainActor
final class ClipboardImagePreviewOpenerTests: XCTestCase {
    func testDataSourceIsWrittenUnchangedBeforeOpeningPreview() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = Data([1, 2, 3, 4])
        let previewApplicationURL = URL(fileURLWithPath: "/Applications/Preview.app")
        let capture = PreviewOpenCapture()
        let opened = expectation(description: "Preview opened")
        let artifactStore = ClipboardImagePreviewArtifactStore(outputDirectory: directory)
        let opener = ClipboardImagePreviewOpener(
            settings: makeSettings(),
            artifactStore: artifactStore,
            resolvePreviewApplication: { previewApplicationURL },
            openInApplication: { urls, applicationURL, completion in
                capture.urls = urls
                capture.applicationURL = applicationURL
                completion(nil, nil)
                opened.fulfill()
            }
        )

        opener.open(
            ClipboardImageEnrichmentRequest(
                generation: 3,
                data: data,
                typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
            )
        )
        await fulfillment(of: [opened], timeout: 1)

        let openedURL = try XCTUnwrap(capture.urls.first)
        XCTAssertEqual(capture.applicationURL, previewApplicationURL)
        XCTAssertEqual(try Data(contentsOf: openedURL), data)
        XCTAssertEqual(openedURL.pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: openedURL.path))
        opener.terminate()
    }

    func testLocalFileUsesExistingURLAndFallsBackWhenPreviewIsUnavailable() throws {
        let directory = makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.png")
        XCTAssertTrue(FileManager.default.createFile(atPath: sourceURL.path, contents: Data([1])))
        let capture = PreviewOpenCapture()
        let artifactStore = ClipboardImagePreviewArtifactStore(outputDirectory: directory)
        let opener = ClipboardImagePreviewOpener(
            settings: makeSettings(),
            artifactStore: artifactStore,
            resolvePreviewApplication: { nil },
            openWithDefaultApplication: { url, completion in
                capture.urls = [url]
                completion(nil, nil)
            }
        )

        opener.open(
            ClipboardImageEnrichmentRequest(
                generation: 4,
                localFileURL: sourceURL,
                typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
            )
        )

        XCTAssertEqual(capture.urls, [sourceURL])
        opener.terminate()
    }
    func testFreshPreviewArtifactSurvivesStoreInitialization() throws {
        let directory = makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifactURL = directory.appendingPathComponent(
            "Sidekick-ClipboardPreview-fresh.png"
        )
        try Data([1, 2, 3]).write(to: artifactURL)

        let store = ClipboardImagePreviewArtifactStore(outputDirectory: directory)

        XCTAssertTrue(FileManager.default.fileExists(atPath: artifactURL.path))
        store.terminate()
    }
    func testOrphanedPartialArtifactIsRemovedDuringRecovery() throws {
        let directory = makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let partialURL = directory.appendingPathComponent(
            "Sidekick-ClipboardPreview-orphan.png.partial-crash"
        )
        try Data([1, 2, 3]).write(to: partialURL)

        let store = ClipboardImagePreviewArtifactStore(outputDirectory: directory)

        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
        store.terminate()
    }

    func testMaterializationStaysWithinArtifactCountBudget() async throws {
        let directory = makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<16 {
            let artifactURL = directory.appendingPathComponent(
                "Sidekick-ClipboardPreview-\(index).png"
            )
            try Data([UInt8(index)]).write(to: artifactURL)
        }

        let store = ClipboardImagePreviewArtifactStore(
            outputDirectory: directory,
            writeData: { data, url, _ in try data.write(to: url) }
        )
        let materialized = expectation(description: "Preview artifact materialized")
        var materializedURL: URL?
        store.materialize(
            data: Data([42]),
            typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
        ) { url in
            materializedURL = url
            materialized.fulfill()
        }
        await fulfillment(of: [materialized], timeout: 1)

        XCTAssertNotNil(materializedURL)
        let artifacts = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("Sidekick-ClipboardPreview-") }
        XCTAssertLessThanOrEqual(artifacts.count, 16)
        store.terminate()
    }

    func testByteBudgetRejectsWhenEvictionFails() throws {
        let directory = makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifactURL = directory.appendingPathComponent(
            "Sidekick-ClipboardPreview-large.png"
        )
        XCTAssertTrue(FileManager.default.createFile(atPath: artifactURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: artifactURL)
        handle.seek(toFileOffset: UInt64(512 * 1_024 * 1_024))
        try handle.write(contentsOf: Data([1]))
        try handle.close()

        let store = ClipboardImagePreviewArtifactStore(
            outputDirectory: directory,
            removeItem: { _ in false }
        )
        var materializedURL: URL?
        store.materialize(
            data: Data([42]),
            typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
        ) { materializedURL = $0 }

        XCTAssertNil(materializedURL)
        store.terminate()
    }

    func testPendingReservationIsReleasedWhenReplaced() async throws {
        let directory = makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<14 {
            let artifactURL = directory.appendingPathComponent(
                "Sidekick-ClipboardPreview-old-\(index).png"
            )
            try Data([UInt8(index)]).write(to: artifactURL)
        }

        let writer = PreviewWriteProbe()
        let removals = PreviewRemovalProbe(successfulRemovals: 2)
        let store = ClipboardImagePreviewArtifactStore(
            outputDirectory: directory,
            writeData: { data, url, _ in
                let partialURL = url.appendingPathExtension("partial-active")
                FileManager.default.createFile(atPath: partialURL.path, contents: Data([0]))
                writer.begin(partialURL)
                writer.waitForRelease()
                defer { try? FileManager.default.removeItem(at: partialURL) }
                try data.write(to: url)
            },
            removeItem: { url in removals.attempt(url) }
        )
        let firstMaterialized = expectation(description: "First preview materialized")
        store.materialize(
            data: Data([1]),
            typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
        ) { _ in firstMaterialized.fulfill() }
        XCTAssertEqual(writer.waitUntilStarted(), .success)

        store.materialize(
            data: Data([2]),
            typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
        ) { _ in XCTFail("Pending preview should be replaced") }
        store.materialize(
            data: Data([3]),
            typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
        ) { _ in XCTFail("Pending preview should remain queued") }

        let fourthEnqueued = expectation(description: "Replacement preview enqueued")
        let fourthMaterialized = expectation(description: "Replacement preview materialized")
        DispatchQueue.main.async {
            store.materialize(
                data: Data([4]),
                typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
            ) { url in
                XCTAssertNotNil(url)
                fourthMaterialized.fulfill()
            }
            fourthEnqueued.fulfill()
        }
        await fulfillment(of: [fourthEnqueued], timeout: 1)
        writer.releaseWrite()
        await fulfillment(of: [firstMaterialized], timeout: 1)
        XCTAssertEqual(writer.waitUntilStarted(), .success)
        writer.releaseWrite()
        await fulfillment(of: [fourthMaterialized], timeout: 1)
        store.terminate()
    }

    func testActiveWriteIsProtectedAndReservedDuringBudgetAdmission() async throws {
        let directory = makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<15 {
            let artifactURL = directory.appendingPathComponent(
                "Sidekick-ClipboardPreview-old-\(index).png"
            )
            try Data([UInt8(index)]).write(to: artifactURL)
        }

        let writer = PreviewWriteProbe()
        let removals = PreviewRemovalProbe()
        let store = ClipboardImagePreviewArtifactStore(
            outputDirectory: directory,
            writeData: { data, url, isCancelled in
                let partialURL = url.appendingPathExtension("partial-active")
                FileManager.default.createFile(atPath: partialURL.path, contents: Data([0]))
                writer.begin(partialURL)
                writer.waitForRelease()
                defer { try? FileManager.default.removeItem(at: partialURL) }
                guard !isCancelled() else { throw CancellationError() }
                try data.write(to: url)
            },
            removeItem: { url in removals.attempt(url) }
        )
        let firstMaterialized = expectation(description: "First preview materialized")
        store.materialize(
            data: Data([1]),
            typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
        ) { url in
            XCTAssertNotNil(url)
            firstMaterialized.fulfill()
        }
        XCTAssertEqual(writer.waitUntilStarted(), .success)
        let partialURL = try XCTUnwrap(writer.partialURL)
        var secondCompletionCount = 0
        store.materialize(
            data: Data([2]),
            typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
        ) { _ in secondCompletionCount += 1 }

        XCTAssertEqual(secondCompletionCount, 1)
        XCTAssertFalse(removals.contains(partialURL))
        writer.releaseWrite()
        await fulfillment(of: [firstMaterialized], timeout: 1)
        store.terminate()
    }

    func testTerminatingActiveWriteCleansLateResult() async throws {
        let directory = makeTemporaryDirectory()
        let writerStarted = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let removed = expectation(description: "Discarded preview artifact removed")
        let store = ClipboardImagePreviewArtifactStore(
            outputDirectory: directory,
            writeData: { data, url, _ in
                writerStarted.signal()
                releaseWriter.wait()
                try data.write(to: url)
            },
            removeItem: { url in
                defer { removed.fulfill() }
                try? FileManager.default.removeItem(at: url)
                return true
            }
        )
        var completionCalled = false
        store.materialize(
            data: Data([3]),
            typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
        ) { _ in completionCalled = true }
        XCTAssertEqual(writerStarted.wait(timeout: .now() + 1), .success)

        store.terminate()
        XCTAssertFalse(completionCalled)
        releaseWriter.signal()
        await fulfillment(of: [removed], timeout: 1)
    }

}

@MainActor
private func makeSettings() -> AppSettings {
    let suiteName = "ClipboardImagePreviewOpenerTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        preconditionFailure("Unable to create test defaults suite")
    }
    return AppSettings(defaults: defaults)
}

private func makeTemporaryDirectory() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(
            ".kilo-tmp/ClipboardImagePreviewOpenerTests.\(UUID().uuidString)",
            isDirectory: true
        )
}

@MainActor
private final class PreviewOpenCapture {
    var urls: [URL] = []
    var applicationURL: URL?
}
private final class PreviewWriteProbe: @unchecked Sendable {
    // These locks protect state shared by the Sendable writer closure and the main-actor test.
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var storedPartialURL: URL?

    var partialURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return storedPartialURL
    }

    func begin(_ partialURL: URL) {
        lock.lock()
        storedPartialURL = partialURL
        lock.unlock()
        started.signal()
    }

    func waitUntilStarted() -> DispatchTimeoutResult {
        started.wait(timeout: .now() + 1)
    }

    func waitForRelease() {
        release.wait()
    }

    func releaseWrite() {
        release.signal()
    }
}

private final class PreviewRemovalProbe: @unchecked Sendable {
    // The lock protects URLs and budget shared by the Sendable removal closure.
    private let lock = NSLock()
    private var urls: [URL] = []
    private var successfulRemovals: Int

    init(successfulRemovals: Int = 0) {
        self.successfulRemovals = successfulRemovals
    }

    func attempt(_ url: URL) -> Bool {
        lock.lock()
        urls.append(url)
        let shouldSucceed = successfulRemovals > 0
        if shouldSucceed {
            successfulRemovals -= 1
        }
        lock.unlock()
        guard shouldSucceed else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    func contains(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return urls.contains(url)
    }
}
