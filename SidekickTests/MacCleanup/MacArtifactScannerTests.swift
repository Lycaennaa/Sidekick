import Foundation
import XCTest

final class MacArtifactScannerTests: XCTestCase {
    func testScannerFindsOnlyConservativeArtifactsInsideOrdinaryFolders() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let nested = root.appendingPathComponent("nested", isDirectory: true)
        let package = root.appendingPathComponent("Tool.app", isDirectory: true)
        let packageContents = package.appendingPathComponent("Contents/Resources", isDirectory: true)
        let outside = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }

        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packageContents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("__MACOSX", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".AppleDouble", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([1]).write(to: nested.appendingPathComponent(".DS_Store"))
        try Data([0, 5, 0x16, 7, 0, 0, 0, 2]).write(to: nested.appendingPathComponent("._document"))
        try Data("ordinary user file".utf8).write(to: nested.appendingPathComponent("._notes"))
        try Data([1]).write(to: root.appendingPathComponent("__MACOSX/._metadata"))
        try Data([1]).write(to: root.appendingPathComponent(".AppleDouble/._metadata"))
        try Data([1]).write(to: packageContents.appendingPathComponent(".DS_Store"))
        try Data([1]).write(to: outside.appendingPathComponent(".DS_Store"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-folder"),
            withDestinationURL: outside
        )

        let result = try MacArtifactScanner.scan(root: root)
        let relativePaths = Set(result.matches.map { $0.url.path.replacingOccurrences(of: root.path + "/", with: "") })

        XCTAssertEqual(
            relativePaths,
            [".AppleDouble", "__MACOSX", "nested/.DS_Store", "nested/._document"]
        )
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testDefaultCleanerDeletesDiscoveredArtifactsOnRealFilesystem() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let desktopDatabase = root.appendingPathComponent(".DS_Store")
        let sidecar = root.appendingPathComponent("._document")
        let metadataDirectory = root.appendingPathComponent("__MACOSX", isDirectory: true)
        try Data([1, 2, 3]).write(to: desktopDatabase)
        try Data([0, 5, 0x16, 7, 0, 0, 0, 2]).write(to: sidecar)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: metadataDirectory.appendingPathComponent("._document"))

        let scan = try MacArtifactScanner.scan(root: root)
        XCTAssertEqual(scan.matches.count, 3)

        let results = scan.matches.map {
            MacArtifactCleaner.apply($0, mode: .deletePermanently)
        }

        XCTAssertEqual(results, [.deleted, .deleted, .deleted])
        XCTAssertFalse(FileManager.default.fileExists(atPath: desktopDatabase.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataDirectory.path))
    }

    func testCleanerPreservesReplacementAtCandidatePath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let candidateURL = root.appendingPathComponent(".DS_Store")
        let replacementURL = root.appendingPathComponent("replacement")
        try Data([1, 2, 3]).write(to: candidateURL)
        let match = try XCTUnwrap(MacArtifactScanner.scan(root: root).matches.first)

        try Data([9, 8, 7, 6]).write(to: replacementURL)
        try FileManager.default.removeItem(at: candidateURL)
        try FileManager.default.moveItem(at: replacementURL, to: candidateURL)

        let result = MacArtifactCleaner.apply(match, mode: .deletePermanently)

        XCTAssertEqual(result, .changedSinceScan)
        XCTAssertEqual(try Data(contentsOf: candidateURL), Data([9, 8, 7, 6]))
    }

    func testTargetedMatcherRejectsPackageSymlinkAndSiblingPaths() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root", isDirectory: true)
        let package = root.appendingPathComponent("Tool.app/Contents", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let sibling = base.appendingPathComponent("root-sibling", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let packageArtifact = package.appendingPathComponent(".DS_Store")
        let linkedArtifact = outside.appendingPathComponent(".DS_Store")
        let siblingArtifact = sibling.appendingPathComponent(".DS_Store")
        try Data([1]).write(to: packageArtifact)
        try Data([1]).write(to: linkedArtifact)
        try Data([1]).write(to: siblingArtifact)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked", isDirectory: true),
            withDestinationURL: outside
        )

        XCTAssertNil(try MacArtifactScanner.match(at: packageArtifact, within: root))
        XCTAssertNil(try MacArtifactScanner.match(
            at: root.appendingPathComponent("linked/.DS_Store"),
            within: root
        ))
        XCTAssertNil(try MacArtifactScanner.match(at: siblingArtifact, within: root))
    }

    func testCleanerPreservesChangedAppleDoubleSidecar() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sidecar = root.appendingPathComponent("._document")
        let original = Data([0, 5, 0x16, 7, 0, 0, 0, 2, 1])
        try original.write(to: sidecar)
        let match = try XCTUnwrap(MacArtifactScanner.scan(root: root).matches.first)

        try Data([0, 5, 0x16, 7, 0, 0, 0, 2, 2]).write(to: sidecar)

        XCTAssertEqual(MacArtifactCleaner.apply(match, mode: .deletePermanently), .changedSinceScan)
        XCTAssertEqual(try Data(contentsOf: sidecar), Data([0, 5, 0x16, 7, 0, 0, 0, 2, 2]))
    }
    func testTargetedMatcherRecognizesAppleDoubleFileByHeader() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sidecar = root.appendingPathComponent("._document")
        try Data([0, 5, 0x16, 7, 0, 0, 0, 2]).write(to: sidecar)

        let match = try MacArtifactScanner.match(at: sidecar, within: root)

        XCTAssertEqual(match?.kind, .appleDoubleSidecar)
    }
    func testScannerFindsArtifactsFromBackgroundFileSystemWorker() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent(".DS_Store")
        try Data([1]).write(to: artifact)

        let worker = Task.detached(priority: .utility) {
            try MacArtifactScanner.scan(root: root)
        }
        let result = try await worker.value

        XCTAssertEqual(result.matches.map(\.url.path), [artifact.path])
    }
    func testPermanentRemovalDoesNotFollowSwappedAncestorSymlink() throws {
        let base = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("root", isDirectory: true)
        let selectedDirectory = root.appendingPathComponent("selected", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        let relocatedDirectory = outside.appendingPathComponent("relocated", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let candidate = selectedDirectory.appendingPathComponent(".DS_Store")
        let sentinel = outside.appendingPathComponent(".DS_Store")
        try Data([1, 2, 3]).write(to: candidate)
        try Data([9, 8, 7]).write(to: sentinel)
        let match = try XCTUnwrap(MacArtifactScanner.scan(root: root).matches.first)

        let removed = try MacArtifactSafeFileSystem.remove(
            match,
            beforeMutation: {
                try FileManager.default.moveItem(at: selectedDirectory, to: relocatedDirectory)
                try FileManager.default.createSymbolicLink(at: selectedDirectory, withDestinationURL: relocatedDirectory)
            }
        )

        XCTAssertFalse(removed)
        let relocatedCandidate = relocatedDirectory.appendingPathComponent(".DS_Store")
        XCTAssertTrue(FileManager.default.fileExists(atPath: relocatedCandidate.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([9, 8, 7]))
        XCTAssertEqual(try Data(contentsOf: relocatedCandidate), Data([1, 2, 3]))
    }


    func testPermanentRemovalRollsBackWhenPostStageValidationThrows() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent(".DS_Store")
        try Data([1, 2, 3]).write(to: candidate)
        let match = try XCTUnwrap(MacArtifactScanner.scan(root: root).matches.first)

        XCTAssertThrowsError(
            try MacArtifactSafeFileSystem.remove(
                match,
                beforeStagedEntryValidation: {
                    throw NSError(domain: "MacArtifactScannerTests", code: 1)
                }
            )
        )
        XCTAssertEqual(try Data(contentsOf: candidate), Data([1, 2, 3]))
    }
    func testPermanentRemovalPreservesLeafReplacementDuringMutation() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent(".DS_Store")
        let original = root.appendingPathComponent("Original")
        try Data([1, 2, 3]).write(to: candidate)
        let match = try XCTUnwrap(MacArtifactScanner.scan(root: root).matches.first)

        let removed = try MacArtifactSafeFileSystem.remove(
            match,
            beforeMutation: {
                try FileManager.default.moveItem(at: candidate, to: original)
                try Data([9, 8, 7]).write(to: candidate)
            }
        )

        XCTAssertFalse(removed)
        XCTAssertEqual(try Data(contentsOf: original), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: candidate), Data([9, 8, 7]))
    }
    func testDefaultCleanerTrashNeverFallsBackToPermanentDeletion() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent(".DS_Store")
        try Data([1, 2, 3]).write(to: candidate)
        let match = try XCTUnwrap(MacArtifactScanner.scan(root: root).matches.first)

        switch MacArtifactCleaner.apply(match, mode: .moveToTrash) {
        case .movedToTrash(let trashedURL):
            defer { try? FileManager.default.removeItem(at: trashedURL) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: trashedURL.path))
        case .failed, .changedSinceScan:
            XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.path))
        case .deleted:
            XCTFail("A Trash failure must never fall back to permanent deletion.")
        case .previewed:
            XCTFail("Trash mode must not report a preview.")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".test-tmp/MacArtifactScannerTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
