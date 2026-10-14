import AppKit
import FinderSync
import Foundation
import XCTest

@MainActor
private final class ModalPromptClicker: NSObject {
    let promptSubmitted: XCTestExpectation
    let buttonTitle: String
    let filenameToType: String?

    init(
        promptSubmitted: XCTestExpectation,
        buttonTitle: String = "Create",
        filenameToType: String? = nil
    ) {
        self.promptSubmitted = promptSubmitted
        self.buttonTitle = buttonTitle
        self.filenameToType = filenameToType
    }

    @objc func clickButtonWhenPromptAppears(_ timer: Timer) {
        guard let contentView = NSApp.modalWindow?.contentView,
              let button = descendantViews(of: contentView)
                  .compactMap({ $0 as? NSButton })
                  .first(where: { $0.title == buttonTitle }) else {
            return
        }
        if let filenameToType {
            guard let filenameField = descendantViews(of: contentView)
                .compactMap({ $0 as? NSTextField })
                .first(where: \.isEditable) else {
                return
            }
            XCTAssertTrue(filenameField.isSelectable)
            filenameField.stringValue = filenameToType
        }
        timer.invalidate()
        button.performClick(nil)
        promptSubmitted.fulfill()
    }

    private func descendantViews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendantViews)
    }
}


final class FinderNewFileTests: XCTestCase {
    @MainActor
    func testCancelCreatesNoFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let promptDismissed = expectation(description: "filename prompt dismissed")
        let clicker = ModalPromptClicker(
            promptSubmitted: promptDismissed,
            buttonTitle: "Cancel"
        )
        let timer = Timer(
            timeInterval: 0.01,
            target: clicker,
            selector: #selector(ModalPromptClicker.clickButtonWhenPromptAppears(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }

        let requestURL = try XCTUnwrap(FinderNewFileRequestURL.make(for: directory))
        FinderNewFileRequestHandler.handle([requestURL])

        await fulfillment(of: [promptDismissed], timeout: 4)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCreateMakesEmptyTypedFileAndDoesNotReplaceExistingItem() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NewFileStore()
        let existingURL = directory.appendingPathComponent("report.md")
        try Data("keep".utf8).write(to: existingURL)
        let presenter = DeletionRecordingFilePresenter(url: existingURL)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        let filename = "typed-name.txt"
        let createdURL = try store.createEmptyFile(in: directory, named: filename)
        XCTAssertEqual(createdURL.lastPathComponent, filename)
        XCTAssertEqual(try fileSize(at: createdURL), 0)

        XCTAssertThrowsError(
            try store.createEmptyFile(in: directory, named: existingURL.lastPathComponent)
        ) { error in
            XCTAssertEqual(error as? NewFileError, .nameAlreadyExists("report.md"))
        }
        XCTAssertFalse(presenter.receivedDeletionRequest)
        XCTAssertEqual(try Data(contentsOf: existingURL), Data("keep".utf8))
    }


    func testInvalidFilenameCannotEscapeTheDestination() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NewFileStore()

        for invalidName in ["", ".", "..", "../outside", "nested/name"] {
            XCTAssertThrowsError(
                try store.createEmptyFile(in: directory, named: invalidName)
            ) { error in
                XCTAssertEqual(error as? NewFileError, .invalidName)
            }
        }

        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.deletingLastPathComponent().appendingPathComponent("outside").path
        ))
    }

    @MainActor
    func testAppHandlesFinderRequestAndCreatesTypedFilename() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let filename = "typed-name.txt"
        let newFileURL = directory.appendingPathComponent(filename)
        let promptSubmitted = expectation(description: "filename prompt submitted")
        let clicker = ModalPromptClicker(
            promptSubmitted: promptSubmitted,
            filenameToType: filename
        )
        let timer = Timer(
            timeInterval: 0.01,
            target: clicker,
            selector: #selector(ModalPromptClicker.clickButtonWhenPromptAppears(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate() }

        let requestURL = try XCTUnwrap(FinderNewFileRequestURL.make(for: directory))
        FinderNewFileRequestHandler.handle([requestURL])

        await fulfillment(of: [promptSubmitted], timeout: 4)
        XCTAssertEqual(try fileSize(at: newFileURL), 0)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("New File").path
        ))
    }

    func testContainerMenuUsesOnlyAnUnambiguousObservedDirectory() throws {
        let firstDirectory = try makeTemporaryDirectory()
        let secondDirectory = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstDirectory)
            try? FileManager.default.removeItem(at: secondDirectory)
        }
        let finderExtension = FinderSyncExtension()

        finderExtension.beginObservingDirectory(at: firstDirectory)
        XCTAssertEqual(
            finderExtension.destinationDirectory(
                for: .contextualMenuForContainer,
                targetedURL: nil
            ),
            firstDirectory
        )

        finderExtension.beginObservingDirectory(at: secondDirectory)
        XCTAssertNil(finderExtension.destinationDirectory(
            for: .contextualMenuForContainer,
            targetedURL: nil
        ))
        finderExtension.endObservingDirectory(at: secondDirectory)
        XCTAssertEqual(
            finderExtension.destinationDirectory(
                for: .contextualMenuForContainer,
                targetedURL: nil
            ),
            firstDirectory
        )
    }

    func testItemMenuAcceptsDirectoriesButNotRegularFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("document")
        try Data("contents".utf8).write(to: file)
        let finderExtension = FinderSyncExtension()

        XCTAssertEqual(
            finderExtension.destinationDirectory(
                for: .contextualMenuForItems,
                targetedURL: folder
            ),
            folder
        )
        XCTAssertNil(finderExtension.destinationDirectory(
            for: .contextualMenuForItems,
            targetedURL: file
        ))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Finder New File Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? -1
    }
}

private final class DeletionRecordingFilePresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let deletionLock = NSLock()
    private var deletionWasRequested = false

    init(url: URL) {
        presentedItemURL = url
        super.init()
    }

    var receivedDeletionRequest: Bool {
        deletionLock.lock()
        defer { deletionLock.unlock() }
        return deletionWasRequested
    }

    func relinquishPresentedItem(
        toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void
    ) {
        writer(nil)
    }

    func accommodatePresentedItemDeletion(
        completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        deletionLock.lock()
        deletionWasRequested = true
        deletionLock.unlock()
        completionHandler(nil)
    }
}
