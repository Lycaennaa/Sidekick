import AppKit
import XCTest

@MainActor
final class ClipboardImageConversionArtifactOwnerTests: XCTestCase {
    func testArtifactOwnerReplacesAndExpiresCurrentArtifact() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        var expiredURL: URL?
        let expiration = expectation(description: "Current artifact expires")
        let firstURL = directory.appendingPathComponent("first01.webp")
        let secondURL = directory.appendingPathComponent("second1.webp")
        let firstCleanup = expectation(description: "First artifact cleanup completed")
        let secondCleanup = expectation(description: "Second artifact cleanup completed")
        let owner = ClipboardImageConversionArtifactOwner(
            expirationInterval: 0.05,
            outputDirectory: directory,
            pasteboard: pasteboard,
            onExpired: { lease in
                expiredURL = lease.url
                expiration.fulfill()
            },
            onCleanupComplete: { url in
                if url == firstURL {
                    firstCleanup.fulfill()
                } else if url == secondURL {
                    secondCleanup.fulfill()
                }
            },
            currentGeneration: { pasteboard.changeCount }
        )
        defer {
            owner.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        try Data([1]).write(to: firstURL)
        owner.claim(url: firstURL, changeCount: 1, token: 1)
        try Data([2]).write(to: secondURL)
        owner.claim(url: secondURL, changeCount: 2, token: 2)
        await fulfillment(of: [firstCleanup], timeout: 1)

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        await fulfillment(of: [expiration], timeout: 1)
        await fulfillment(of: [secondCleanup], timeout: 1)
        XCTAssertEqual(expiredURL, secondURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertNil(owner.currentLease)
    }

    func testSameURLExternalRewriteRetainsArtifactWithoutRestoringOwnership() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("Ref1234.webp")
        let firstCleanup = expectation(description: "First URL cleanup completed")
        let secondCleanup = expectation(description: "Second URL cleanup completed")
        var cleanupCount = 0
        let owner = ClipboardImageConversionArtifactOwner(
            expirationInterval: 60,
            outputDirectory: directory,
            pasteboard: pasteboard,
            onCleanupComplete: { _ in
                if cleanupCount == 0 {
                    firstCleanup.fulfill()
                } else {
                    secondCleanup.fulfill()
                }
                cleanupCount += 1
            },
            currentGeneration: { pasteboard.changeCount }
        )
        defer {
            owner.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        try Data([1]).write(to: url)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(url.absoluteString, forType: .fileURL))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let lease = owner.claim(url: url, changeCount: pasteboard.changeCount, token: 1)

        pasteboard.clearContents()
        let replacementItem = NSPasteboardItem()
        XCTAssertTrue(replacementItem.setString(url.absoluteString, forType: .fileURL))
        XCTAssertTrue(pasteboard.writeObjects([replacementItem]))
        XCTAssertNotEqual(pasteboard.changeCount, lease.changeCount)
        owner.discard(lease)
        await fulfillment(of: [firstCleanup], timeout: 1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(owner.currentLease)

        pasteboard.clearContents()
        owner.discard(lease)
        await fulfillment(of: [secondCleanup], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(owner.currentLease)
    }

    func testTerminationDoesNotScheduleCleanupRetryAfterDeletionFailure() async throws {
        let directory = try temporaryDirectory()
        let pasteboard = makeTransactionalPasteboard()
        var removeAttempts = 0
        let cleanupCompleted = expectation(description: "Failed cleanup completed")
        let owner = ClipboardImageConversionArtifactOwner(
            expirationInterval: 60,
            outputDirectory: directory,
            pasteboard: pasteboard,
            removeItem: { _ in
                removeAttempts += 1
                throw NSError(domain: "ClipboardImageConversionArtifactOwnerTests", code: 1)
            },
            onCleanupComplete: { _ in cleanupCompleted.fulfill() },
            currentGeneration: { pasteboard.changeCount }
        )
        defer {
            owner.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        let url = directory.appendingPathComponent("Failed1.webp")
        try Data([1]).write(to: url)
        owner.claim(url: url, changeCount: 1, token: 1)

        owner.terminate()
        await fulfillment(of: [cleanupCompleted], timeout: 1)
        let attemptsAtTermination = removeAttempts
        XCTAssertTrue(owner.isTerminated)
        XCTAssertNil(owner.currentLease)

        try await Task.sleep(for: .milliseconds(1_100))

        XCTAssertEqual(removeAttempts, attemptsAtTermination)
        XCTAssertTrue(owner.isTerminated)
        XCTAssertNil(owner.currentLease)
    }

    func testStartupCleanupOnlyRemovesOwnedUnreferencedArtifacts() async throws {
        let directory = try temporaryDirectory()
        let pasteboard = makeTransactionalPasteboard()
        let ownedURL = directory.appendingPathComponent(
            "Owned01.webp"
        )
        let partialURL = directory.appendingPathComponent(
            "Part123.webp.partial-recovery"
        )
        let referencedURL = directory.appendingPathComponent(
            "Ref1234.webp"
        )
        let unrelatedURL = directory.appendingPathComponent("stale.webp")
        let ownedDirectory = directory.appendingPathComponent(
            "Folder1.webp",
            isDirectory: true
        )
        try Data([1]).write(to: ownedURL)
        try Data([2]).write(to: partialURL)
        try Data([3]).write(to: referencedURL)
        try Data([4]).write(to: unrelatedURL)
        try FileManager.default.createDirectory(
            at: ownedDirectory,
            withIntermediateDirectories: false
        )
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(referencedURL.absoluteString, forType: .fileURL))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let owner = ClipboardImageConversionArtifactOwner(
            expirationInterval: 60,
            outputDirectory: directory,
            pasteboard: pasteboard,
             fileURLReader: InlinePasteboardFileURLReader(),
            currentGeneration: { pasteboard.changeCount }
        )
        defer {
            owner.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        await owner.waitForStartupCleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partialURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: referencedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedDirectory.path))
    }

    func testOutputOwnershipRequiresExactScopedGeneratedName() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertTrue(ClipboardImageConversionFileService.isOwnedOutputURL(
            directory.appendingPathComponent("Valid01.webp"),
            in: directory
        ))
        XCTAssertTrue(ClipboardImageConversionFileService.isOwnedOutputURL(
            directory.appendingPathComponent(
                "Valid01.webp.partial-worker"
            ),
            in: directory
        ))
        XCTAssertFalse(ClipboardImageConversionFileService.isOwnedOutputURL(
            directory.appendingPathComponent("stale.webp"),
            in: directory
        ))
        XCTAssertFalse(ClipboardImageConversionFileService.isOwnedOutputURL(
            directory.appendingPathComponent("äbc1234.webp"),
            in: directory
        ))
        XCTAssertFalse(ClipboardImageConversionFileService.isOwnedOutputURL(
            directory.appendingPathComponent("Valid01.webp.partial-"),
            in: directory
        ))
    }

    func testAppKitPasteboardConditionalCleanupDeletesUnreferencedArtifact() async throws {
        let directory = try temporaryDirectory()
        let pasteboard = makePasteboard()
        let url = directory.appendingPathComponent(
            "AppKit1.webp"
        )
        try Data([1]).write(to: url)
        let owner = ClipboardImageConversionArtifactOwner(
            expirationInterval: 60,
            outputDirectory: directory,
            pasteboard: pasteboard,
             fileURLReader: InlinePasteboardFileURLReader(),
            currentGeneration: { pasteboard.changeCount }
        )
        defer {
            owner.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        await owner.waitForStartupCleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testUncertainPasteboardReferenceRetainsArtifact() async throws {
        let directory = try temporaryDirectory()
        let pasteboard = makeTransactionalPasteboard()
        let url = directory.appendingPathComponent(
            "Uncert1.webp"
        )
        try Data([1]).write(to: url)
        var items: [NSPasteboardItem] = []
        for index in 0...PasteboardSnapshotPolicy.maximumItems {
            let item = NSPasteboardItem()
            let value = index == 0
                ? url.absoluteString
                : "file:///tmp/unrelated-\(index)"
            XCTAssertTrue(item.setString(value, forType: .fileURL))
            items.append(item)
        }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects(items))
        let cleanupCompleted = expectation(description: "Uncertain cleanup completed")
        let owner = ClipboardImageConversionArtifactOwner(
            expirationInterval: 60,
            outputDirectory: directory,
            pasteboard: pasteboard,
            onCleanupComplete: { _ in cleanupCompleted.fulfill() },
            currentGeneration: { pasteboard.changeCount }
        )
        defer {
            owner.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        await owner.waitForStartupCleanup()

        let lease = owner.claim(url: url, changeCount: pasteboard.changeCount, token: 1)
        owner.discard(lease)
        await fulfillment(of: [cleanupCompleted], timeout: 1)

        XCTAssertNil(owner.currentLease)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testStartupCleanupRetainsArtifactWhenGenerationChangesDuringReferenceCheck() async throws {
        let directory = try temporaryDirectory()
        let pasteboard = makeTransactionalPasteboard()
        let url = directory.appendingPathComponent(
            "Race001.webp"
        )
        try Data([1]).write(to: url)
        pasteboard.beforeNextArtifactDeletionMutation = {
            pasteboard.clearContents()
            pasteboard.setString("new clipboard value", forType: .string)
        }
        let owner = ClipboardImageConversionArtifactOwner(
            expirationInterval: 60,
            outputDirectory: directory,
            pasteboard: pasteboard,
            currentGeneration: { pasteboard.changeCount }
        )
        defer {
            owner.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        await owner.waitForStartupCleanup()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testCleanupRetainsArtifactWhenGenerationChangesDuringReferenceCheck() async throws {
        let directory = try temporaryDirectory()
        let pasteboard = makeTransactionalPasteboard()
        let url = directory.appendingPathComponent(
            "Race002.webp"
        )
        try Data([1]).write(to: url)
        pasteboard.beforeNextArtifactDeletionMutation = {
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            _ = item.setString(url.absoluteString, forType: .fileURL)
            _ = pasteboard.writeObjects([item])
        }
        let cleanupCompleted = expectation(description: "Racing cleanup completed")
        let owner = ClipboardImageConversionArtifactOwner(
            expirationInterval: 60,
            outputDirectory: directory,
            pasteboard: pasteboard,
            onCleanupComplete: { _ in cleanupCompleted.fulfill() },
            currentGeneration: { pasteboard.changeCount }
        )
        defer {
            owner.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        await owner.waitForStartupCleanup()

        owner.removeGeneratedFile(at: url)
        await fulfillment(of: [cleanupCompleted], timeout: 1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testStaleLeaseCannotRemoveCurrentSameURLGeneration() async throws {
        let directory = try temporaryDirectory()
        let pasteboard = makeTransactionalPasteboard()
        let url = directory.appendingPathComponent(
            "Same001.webp"
        )
        try Data([1]).write(to: url)
        let cleanupCompleted = expectation(description: "Stale lease cleanup completed")
        let owner = ClipboardImageConversionArtifactOwner(
            expirationInterval: 60,
            outputDirectory: directory,
            pasteboard: pasteboard,
            onCleanupComplete: { _ in cleanupCompleted.fulfill() },
            currentGeneration: { pasteboard.changeCount }
        )
        defer {
            owner.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        let firstLease = owner.claim(url: url, changeCount: 1, token: 1)
        let currentLease = owner.claim(url: url, changeCount: 2, token: 2)
        owner.discard(firstLease)

        XCTAssertEqual(owner.currentLease, currentLease)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        owner.discard(currentLease)
        await fulfillment(of: [cleanupCompleted], timeout: 1)
        XCTAssertNil(owner.currentLease)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testUniqueOutputURLUsesAuthenticatedSevenCharacterName() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try ClipboardImageConversionFileService.uniqueOutputURL(
            in: directory,
            isCancelled: { false }
        )

        XCTAssertTrue(ClipboardImageConversionFileService.isOwnedOutputURL(url, in: directory))
        XCTAssertEqual(
            url.lastPathComponent.count,
            7 + ".webp".count
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

@MainActor
private final class RestoreOwnershipGate {
    let started = XCTestExpectation(description: "Lease ownership check suspended")
    private var continuation: CheckedContinuation<Bool, Never>?

    func check() async -> Bool {
        started.fulfill()
        return await withCheckedContinuation { continuation = $0 }
    }

    func resume(owned: Bool) {
        continuation?.resume(returning: owned)
        continuation = nil
    }
}
@MainActor
final class ClipboardImageConversionArtifactOwnerRestoreRaceTests: XCTestCase {
    func testRestoreKeepsNewerLeaseClaimedDuringOwnershipValidation() async throws {
        let pasteboard = makeTransactionalPasteboard()
        let directory = try temporaryDirectory()
        let previousURL = directory.appendingPathComponent("Previous1.webp")
        let newerURL = directory.appendingPathComponent("Newer001.webp")
        let owner = ClipboardImageConversionArtifactOwner(
            expirationInterval: 60,
            outputDirectory: directory,
            pasteboard: pasteboard,
            currentGeneration: { pasteboard.changeCount }
        )
        defer {
            owner.terminate()
            try? FileManager.default.removeItem(at: directory)
        }

        try Data([1]).write(to: previousURL)
        let previousLease = owner.claim(url: previousURL, changeCount: 1, token: 1)
        let ownershipGate = RestoreOwnershipGate()
        let restoreTask = Task { @MainActor in
            await owner.restore(previousLease, changeCount: 2) {
                await ownershipGate.check()
            }
        }

        await fulfillment(of: [ownershipGate.started], timeout: 1)
        try Data([2]).write(to: newerURL)
        pasteboard.changeCount = 2
        let newerLease = owner.claim(url: newerURL, changeCount: 2, token: 2)
        ownershipGate.resume(owned: true)
        await restoreTask.value

        XCTAssertEqual(owner.currentLease, newerLease)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newerURL.path))
    }
}
