import AppKit
import XCTest

@MainActor
final class PasteboardSnapshotTransactionTests: XCTestCase {
    private let limits = PasteboardSnapshot.Limits(
        maximumBytes: 16,
        maximumItems: 2,
        maximumTypesPerItem: 2
    )

    func testCaptureRejectsStaleAndOversizedInputs() async {
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [
            makePasteboardSnapshotItem(text: "original")
        ])

        if case .stale = await PasteboardSnapshot.capture(
            from: pasteboard,
            expectedChangeCount: pasteboard.changeCount + 1,
            limits: limits
        ) {} else {
            XCTFail("Expected stale capture")
        }

        pasteboard.items = [makePasteboardSnapshotItem(text: "0123456789abcdefg")]
        if case .failed = await PasteboardSnapshot.capture(
            from: pasteboard,
            expectedChangeCount: pasteboard.changeCount,
            limits: limits
        ) {} else {
            XCTFail("Expected bounded capture failure")
        }
    }

    func testCaptureDetectsChangeWhileReadingItems() async {
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [
            makePasteboardSnapshotItem(text: "original")
        ])
        let expectedChangeCount = pasteboard.changeCount
        pasteboard.changeCountAfterNextItemsRead = true

        if case .stale = await PasteboardSnapshot.capture(
            from: pasteboard,
            expectedChangeCount: expectedChangeCount,
            limits: limits
        ) {} else {
            XCTFail("Expected stale capture")
        }
    }

    func testCaptureRejectsItemCountBeforeReadingPayload() async {
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [
            makePasteboardSnapshotItem(text: "one"),
            makePasteboardSnapshotItem(text: "two"),
            makePasteboardSnapshotItem(text: "three")
        ])

        if case .failed = await PasteboardSnapshot.capture(
            from: pasteboard,
            expectedChangeCount: pasteboard.changeCount,
            limits: limits
        ) {} else {
            XCTFail("Expected item-count limit failure")
        }
    }

    func testFailedVerificationRestoresOriginalClipboard() async throws {
        let original = makePasteboardSnapshotItem(text: "original")
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [original])
        let expectedChangeCount = pasteboard.changeCount
        let snapshot = try await capturedSnapshot(from: pasteboard)
        pasteboard.writeResults = [true, true]

        let result = await snapshot.replace(
            pasteboard: pasteboard,
            expectedChangeCount: expectedChangeCount,
            with: [makePasteboardSnapshotItem(text: "replacement")],
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader(),
            verify: { false }
        )

        guard case let .failed(restoredChangeCount) = result else {
            return XCTFail("Expected restored replacement failure")
        }
        XCTAssertEqual(restoredChangeCount, pasteboard.changeCount)
        XCTAssertEqual(
            pasteboard.items.first?.string(forType: .string),
            "original"
        )
    }
    func testFailedWriteRestoresOriginalClipboard() async throws {
        let original = makePasteboardSnapshotItem(text: "original")
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [original])
        let expectedChangeCount = pasteboard.changeCount
        let snapshot = try await capturedSnapshot(from: pasteboard)
        pasteboard.writeResults = [false, true]

        let result = await snapshot.replace(
            pasteboard: pasteboard,
            expectedChangeCount: expectedChangeCount,
            with: [makePasteboardSnapshotItem(text: "replacement")],
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader(),
            verify: { true }
        )

        guard case let .failed(restoredChangeCount) = result else {
            return XCTFail("Expected failed write to restore original clipboard")
        }
        XCTAssertEqual(restoredChangeCount, pasteboard.changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testRestoreFailureIsSurfaced() async throws {
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [
            makePasteboardSnapshotItem(text: "original")
        ])
        let expectedChangeCount = pasteboard.changeCount
        let snapshot = try await capturedSnapshot(from: pasteboard)
        pasteboard.writeResults = [true, false]

        let result = await snapshot.replace(
            pasteboard: pasteboard,
            expectedChangeCount: expectedChangeCount,
            with: [makePasteboardSnapshotItem(text: "replacement")],
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader(),
            verify: { false }
        )

        if case .restoreFailed = result {} else {
            XCTFail("Expected restore failure")
        }
    }

    func testReplacementFailsClosedWhenGenerationChangesBeforeConditionalMutation() async throws {
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [
            makePasteboardSnapshotItem(text: "original")
        ])
        let expectedChangeCount = pasteboard.changeCount
        let snapshot = try await capturedSnapshot(from: pasteboard)
        pasteboard.beforeNextConditionalMutation = {
            pasteboard.clearContents()
            pasteboard.setString("new clipboard", forType: .string)
        }

        let result = await snapshot.replace(
            pasteboard: pasteboard,
            expectedChangeCount: expectedChangeCount,
            with: [makePasteboardSnapshotItem(text: "replacement")],
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader(),
            verify: { true }
        )

        guard case .stale = result else {
            return XCTFail("Expected replacement to fail closed after a generation change")
        }
        XCTAssertEqual(
            pasteboard.items.first?.string(forType: .string),
            "new clipboard"
        )
    }
    func testReplacementReturnsStaleWhenClipboardChangesDuringMaterialization() async throws {
        let original = makePasteboardSnapshotItem(text: "original")
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [original])
        let expectedChangeCount = pasteboard.changeCount
        let snapshot = try await capturedSnapshot(from: pasteboard)
        let payloadReader = ExternalWriteDuringMaterializationPayloadReader(
            pasteboard: pasteboard
        )

        let result = await snapshot.replace(
            pasteboard: pasteboard,
            expectedChangeCount: expectedChangeCount,
            with: [makePasteboardSnapshotItem(text: "replacement")],
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: payloadReader,
            verify: { true }
        )

        guard case .stale = result else {
            return XCTFail("Expected materialization interleaving to be stale")
        }
        XCTAssertEqual(payloadReader.readCount, 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "new clipboard")
    }

    func testVerificationRaceDoesNotRestoreOverNewClipboard() async throws {
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [
            makePasteboardSnapshotItem(text: "original")
        ])
        let expectedChangeCount = pasteboard.changeCount
        let snapshot = try await capturedSnapshot(from: pasteboard)

        let result = await snapshot.replace(
            pasteboard: pasteboard,
            expectedChangeCount: expectedChangeCount,
            with: [makePasteboardSnapshotItem(text: "replacement")],
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader(),
            verify: {
                pasteboard.setString("new clipboard", forType: .string)
                return false
            }
        )

        guard case .stale = result else {
            return XCTFail("Expected rollback to fail closed after a newer write")
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "new clipboard")
    }

    func testAppKitPasteboardConditionalReplacementSucceeds() async {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PasteboardSnapshotTransactionTests-\(UUID().uuidString)")
        )
        let original = makePasteboardSnapshotItem(text: "original")
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([original]))
        let originalChangeCount = pasteboard.changeCount
        let snapshot = PasteboardSnapshot(items: [original])
        let replacement = makePasteboardSnapshotItem(text: "replacement")

        let result = await snapshot.replace(
            pasteboard: pasteboard,
            expectedChangeCount: originalChangeCount,
            with: [replacement],
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader(),
            verify: { true }
        )

        guard case let .installed(changeCount) = result else {
            return XCTFail("Expected AppKit transaction to install replacement, got \(result)")
        }
        XCTAssertEqual(changeCount, pasteboard.changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "replacement")
    }

    func testAppKitPasteboardTransactionLeavesNewerContentsUntouched() async {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PasteboardSnapshotTransactionTests-\(UUID().uuidString)")
        )
        let original = makePasteboardSnapshotItem(text: "original")
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([original]))
        let originalChangeCount = pasteboard.changeCount
        let snapshot = PasteboardSnapshot(items: [original])
        let replacement = makePasteboardSnapshotItem(text: "replacement")

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("new clipboard", forType: .string))
        let newerChangeCount = pasteboard.changeCount

        let newerResult = await snapshot.replace(
            pasteboard: pasteboard,
            expectedChangeCount: originalChangeCount,
            with: [replacement],
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader(),
            verify: { true }
        )
        guard case .stale = newerResult else {
            return XCTFail("Expected newer AppKit contents to remain untouched")
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "new clipboard")

        let mismatchedResult = await pasteboard.replaceContentsIfCurrent(
            request: PasteboardReplacementRequest(
                expectedChangeCount: newerChangeCount,
                expectedItems: [original],
                replacementObjects: [replacement],
                rollbackItems: [original],
                configuration: PasteboardSnapshot.ContentMatchConfiguration(
                    maximumBytes: 16 * 1_024 * 1_024,
                    maximumTypesPerItem: PasteboardSnapshotPolicy.maximumTypesPerItem,
                    fileURLReader: InlinePasteboardFileURLReader(),
                    payloadReader: InlinePasteboardPayloadReader()
                ),
                isStillOwned: { true },
                onMutation: nil,
                verify: nil
            )
        )
        guard case .stale = mismatchedResult else {
            return XCTFail("Expected AppKit conditional transaction to reject mutation without atomicity")
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "new clipboard")
    }

    func testAppKitPasteboardVerificationFailureRestoresOriginal() async {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PasteboardSnapshotTransactionTests-\(UUID().uuidString)")
        )
        let original = makePasteboardSnapshotItem(text: "original")
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([original]))
        let originalChangeCount = pasteboard.changeCount
        let snapshot = PasteboardSnapshot(items: [makePasteboardSnapshotItem(text: "original")])
        let replacement = makePasteboardSnapshotItem(text: "replacement")

        let result = await snapshot.replace(
            pasteboard: pasteboard,
            expectedChangeCount: originalChangeCount,
            with: [replacement],
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: InlinePasteboardPayloadReader(),
            verify: { false }
        )

        guard case let .failed(restoredChangeCount) = result else {
            return XCTFail("Expected AppKit verification failure to restore original, got \(result)")
        }
        XCTAssertEqual(restoredChangeCount, pasteboard.changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testCancellationDuringPostWriteVerificationRestoresOriginalClipboard() async throws {
        let pasteboard = PasteboardSnapshotFakePasteboard(
            items: [makePasteboardSnapshotItem(text: "original")]
        )
        let originalChangeCount = pasteboard.changeCount
        let snapshot = try await capturedSnapshot(from: pasteboard)
        let replacement = makePasteboardSnapshotItem(text: "replacement")
        let gate = PostWriteVerificationGate()
        let operation = Task { @MainActor in
            await snapshot.replace(
                pasteboard: pasteboard,
                expectedChangeCount: originalChangeCount,
                with: [replacement],
                payloadReader: InlinePasteboardPayloadReader(),
                isStillOwned: { true },
                verify: { await gate.verify() }
            )
        }

        await gate.waitUntilVerificationStarts()
        XCTAssertEqual(pasteboard.string(forType: .string), "replacement")
        operation.cancel()
        gate.resumeVerification()
        let result = await operation.value

        guard case let .failed(restoredChangeCount) = result else {
            return XCTFail("Cancellation during verification must restore the source clipboard")
        }
        XCTAssertEqual(restoredChangeCount, pasteboard.changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    private func capturedSnapshot(
        from pasteboard: PasteboardSnapshotFakePasteboard
    ) async throws -> PasteboardSnapshot {
        var copies: [NSPasteboardItem] = []
        for sourceItem in pasteboard.items {
            let copy = NSPasteboardItem()
            for type in sourceItem.types {
                guard let data = sourceItem.data(forType: type),
                      copy.setData(data, forType: type) else {
                    throw TestError.captureFailed
                }
            }
            copies.append(copy)
        }
        return PasteboardSnapshot(items: copies)
    }

    private enum TestError: Error {
        case captureFailed
    }
}
@MainActor
private final class ExternalWriteDuringMaterializationPayloadReader: PasteboardPayloadReading {
    private let pasteboard: PasteboardSnapshotFakePasteboard
    private(set) var readCount = 0

    init(pasteboard: PasteboardSnapshotFakePasteboard) {
        self.pasteboard = pasteboard
    }

    func readData(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int
    ) async -> PasteboardPayloadReader.Result {
        guard !Task.isCancelled, maximumBytes >= 0 else { return .missing }
        readCount += 1
        if readCount == 1 {
            pasteboard.setString("new clipboard", forType: .string)
        }
        guard let data = item.data(forType: type) else { return .missing }
        guard data.count <= maximumBytes else {
            return .tooLarge(byteCount: data.count)
        }
        return .data(data)
    }
}
@MainActor
private final class PostWriteVerificationGate {
    private var hasStarted = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var verificationContinuation: CheckedContinuation<Void, Never>?

    func verify() async -> Bool {
        await withCheckedContinuation { continuation in
            verificationContinuation = continuation
            hasStarted = true
            let currentWaiters = waiters
            waiters.removeAll()
            currentWaiters.forEach { $0.resume() }
        }
        return true
    }

    func waitUntilVerificationStarts() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func resumeVerification() {
        verificationContinuation?.resume()
        verificationContinuation = nil
    }
}
extension PasteboardSnapshotTransactionTests {
    func testAppKitPasteboardConditionalClearClearsOwnedArtifact() async {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PasteboardSnapshotTransactionTests-\(UUID().uuidString)")
        )
        let matchingURL = URL(fileURLWithPath: "fixture.webp").standardizedFileURL
        let original = NSPasteboardItem()
        XCTAssertTrue(original.setString(matchingURL.absoluteString, forType: .fileURL))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([original]))
        let originalChangeCount = pasteboard.changeCount
        let configuration = PasteboardSnapshot.FileURLConfiguration(
            maximumItems: 2,
            maximumTypesPerItem: 2,
            maximumReadDuration: PasteboardSnapshot.maximumFileURLReadDuration,
            fileURLReader: InlinePasteboardFileURLReader()
        )
        let result = await pasteboard.clearContentsIfCurrent(
            expectedChangeCount: originalChangeCount,
            matchingFileURL: matchingURL,
            configuration: configuration,
            isStillOwned: { true }
        )

        guard case let .cleared(changeCount) = result else {
            return XCTFail("Expected owned AppKit clipboard to clear, got \(result)")
        }
        XCTAssertEqual(changeCount, pasteboard.changeCount)
        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
        XCTAssertNil(pasteboard.string(forType: .fileURL))
    }
}
