import AppKit
import XCTest

@MainActor
func makePasteboardSnapshotItem(text: String) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    return item
}

@MainActor
final class InlinePasteboardPayloadReader: PasteboardPayloadReading {
    func readData(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int
    ) async -> PasteboardPayloadReader.Result {
        guard !Task.isCancelled, maximumBytes >= 0 else { return .missing }
        guard let data = item.data(forType: type) else { return .missing }
        guard data.count <= maximumBytes else {
            return .tooLarge(byteCount: data.count)
        }
        return .data(data)
    }
}

@MainActor
final class InlinePasteboardFileURLReader: PasteboardFileURLReading {
    func readFileURLData(
        from item: NSPasteboardItem,
        maximumBytes: Int,
        timeout: TimeInterval
    ) async -> PasteboardFileURLReadResult {
        guard !Task.isCancelled,
              maximumBytes >= 0,
              timeout.isFinite,
              timeout >= 0 else {
            return .unavailable
        }
        guard let data = item.data(forType: .fileURL) else { return .missing }
        guard data.count <= maximumBytes else {
            return .tooLarge(byteCount: data.count)
        }
        return .data(data)
    }
}

@MainActor
final class PasteboardSnapshotFakePasteboard: PasteboardAccess, PasteboardOwnershipTransaction {
    var changeCount = 1
    var items: [NSPasteboardItem]
    var writeResults: [Bool] = []
    var changeCountAfterNextItemsRead = false
    var itemsAfterNextClear: [NSPasteboardItem]?
    var beforeNextConditionalMutation: (() -> Void)?
    var beforeNextConditionalClear: (() -> Void)?
    var beforeNextArtifactDeletionMutation: (() -> Void)?

    private var transactionCoordinator: PasteboardTransactionCoordinator {
        PasteboardTransactionCoordinator(pasteboard: self)
    }

    var pasteboardItems: [NSPasteboardItem]? {
        if changeCountAfterNextItemsRead {
            changeCountAfterNextItemsRead = false
            changeCount += 1
        }
        let currentItems = items
        runNextRaceInjection()
        return currentItems
    }

    init(items: [NSPasteboardItem]) {
        self.items = items
    }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        items.lazy.compactMap { $0.data(forType: type) }.first
    }

    func string(forType type: NSPasteboard.PasteboardType) -> String? {
        items.lazy.compactMap { $0.string(forType: type) }.first
    }

    @discardableResult
    func setData(_ data: Data, forType type: NSPasteboard.PasteboardType) -> Bool {
        clearContents()
        let item = NSPasteboardItem()
        guard item.setData(data, forType: type) else { return false }
        return writeObjects([item])
    }

    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        clearContents()
        let item = NSPasteboardItem()
        guard item.setString(string, forType: type) else { return false }
        return writeObjects([item])
    }

    @discardableResult
    func clearContents() -> Int {
        let returnedChangeCount = changeCount + 1
        changeCount = returnedChangeCount
        items = []
        if let replacement = itemsAfterNextClear {
            itemsAfterNextClear = nil
            changeCount += 1
            items = replacement
        }
        return returnedChangeCount
    }

    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool {
        let succeeds = writeResults.isEmpty ? true : writeResults.removeFirst()
        if succeeds {
            items = objects.compactMap { $0 as? NSPasteboardItem }
        }
        return succeeds
    }

    func replaceContentsIfCurrent(
        request: PasteboardReplacementRequest
    ) async -> PasteboardSnapshot.ReplacementResult {
        await transactionCoordinator.replaceContentsIfCurrent(request: request)
    }

    func clearContentsIfCurrent(
        expectedChangeCount: Int,
        matchingFileURL: URL,
        configuration: PasteboardSnapshot.FileURLConfiguration,
        isStillOwned: @escaping @MainActor () -> Bool
    ) async -> PasteboardConditionalClearResult {
        await transactionCoordinator.clearContentsIfCurrent(
            expectedChangeCount: expectedChangeCount,
            matchingFileURL: matchingFileURL,
            configuration: configuration,
            isStillOwned: isStillOwned
        )
    }

    func deleteFileIfUnreferenced(
        _ url: URL,
        expectedChangeCount: Int,
        configuration: PasteboardSnapshot.FileURLConfiguration,
        isStillOwned: @escaping @MainActor () -> Bool,
        removeItem: @escaping @MainActor (URL) throws -> Void
    ) async -> PasteboardConditionalArtifactDeletionResult {
        await transactionCoordinator.deleteFileIfUnreferenced(
            url,
            expectedChangeCount: expectedChangeCount,
            configuration: configuration,
            isStillOwned: isStillOwned,
            removeItem: removeItem
        )
    }

    private func runNextRaceInjection() {
        if let action = beforeNextConditionalMutation {
            beforeNextConditionalMutation = nil
            action()
        } else if let action = beforeNextConditionalClear {
            beforeNextConditionalClear = nil
            action()
        } else if let action = beforeNextArtifactDeletionMutation {
            beforeNextArtifactDeletionMutation = nil
            action()
        }
    }
}

final class PasteboardSnapshotBlockingDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    let data: Data
    let started: XCTestExpectation?
    let finished: XCTestExpectation?
    let release = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var item: NSPasteboardItem?
    private let lock = NSLock()
    private var invocations = 0

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }

    init(
        data: Data,
        started: XCTestExpectation? = nil,
        finished: XCTestExpectation? = nil
    ) {
        self.data = data
        self.started = started
        self.finished = finished
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        lock.lock()
        invocations += 1
        lock.unlock()
        started?.fulfill()
        release.wait()
        item.setData(data, forType: type)
        finished?.fulfill()
    }
}
final class PasteboardProviderBlockingMaterializer: @unchecked Sendable {
    let data: Data
    let started: XCTestExpectation
    let finished: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var invocations = 0

    init(data: Data, expectedInvocationCount: Int) {
        self.data = data
        started = XCTestExpectation(description: "Injected provider materialization started")
        started.expectedFulfillmentCount = expectedInvocationCount
        finished = XCTestExpectation(description: "Injected provider materialization finished")
        finished.expectedFulfillmentCount = expectedInvocationCount
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }

    func materialize(
        _ isActive: @Sendable () -> Bool
    ) -> PasteboardProviderMaterialization {
        lock.lock()
        invocations += 1
        lock.unlock()
        started.fulfill()
        release.wait()
        _ = isActive()
        finished.fulfill()
        return .data(data)
    }
}

@MainActor
final class PasteboardSnapshotBlockingFileURLReader: PasteboardFileURLReading {
    let started = XCTestExpectation(description: "Injected file URL reader started")
    private var continuation: CheckedContinuation<PasteboardFileURLReadResult, Never>?
    private(set) var readCount = 0

    func readFileURLData(
        from item: NSPasteboardItem,
        maximumBytes: Int,
        timeout: TimeInterval
    ) async -> PasteboardFileURLReadResult {
        readCount += 1
        started.fulfill()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(_ result: PasteboardFileURLReadResult) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }
}
