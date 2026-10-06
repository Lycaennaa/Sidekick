import AppKit
import XCTest

@MainActor
final class PasteboardFileProviderTests: XCTestCase {
    func testInjectedMaterializerDoesNotBlockMainActor() async {
        let owner = PasteboardProviderOperationOwner(
            maximumConcurrentOperations: 1,
            maximumQueuedOperations: 0
        )
        let materializer = PasteboardProviderBlockingMaterializer(
            data: Data([1, 2, 3]),
            expectedInvocationCount: 1
        )
        defer { materializer.release.signal() }

        let task = Task { @MainActor in
            await owner.readData(
                maximumBytes: 8,
                timeout: 10,
                materialize: { isActive in materializer.materialize(isActive) }
            )
        }
        await fulfillment(of: [materializer.started], timeout: 1)
        let mainActorProbe = Task { @MainActor in true }
        let mainActorProbeCompleted = await mainActorProbe.value
        XCTAssertTrue(mainActorProbeCompleted)

        materializer.release.signal()
        guard case let .data(data) = await task.value else {
            return XCTFail("Expected injected materializer data")
        }
        XCTAssertEqual(data, Data([1, 2, 3]))
    }

    func testNativeProviderPayloadReturnsAtDeadlineWhileProviderContinues() async {
        let finished = expectation(description: "Native provider payload finished")
        let provider = PasteboardSnapshotBlockingDataProvider(
            data: Data([1, 2, 3]),
            finished: finished
        )
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.png]))
        defer { provider.release.signal() }

        guard case .timedOut = await PasteboardPayloadReader.readData(
            from: item,
            forType: .png,
            maximumBytes: 2
        ) else {
            return XCTFail(
                "Expected the native payload deadline to fail closed while the provider remained blocked"
            )
        }
        XCTAssertEqual(provider.invocationCount, 1)
        provider.release.signal()
        await fulfillment(of: [finished], timeout: 1)
    }

    func testExplicitMaterializerRejectsOversizedData() async {
        let result = await SystemPasteboardFileURLReader.readInjectedData(
            maximumBytes: 2,
            timeout: 1,
            materialize: { Data([1, 2, 3]) }
        )
        guard case let .tooLarge(byteCount) = result else {
            return XCTFail("Expected oversized explicit materialization")
        }
        XCTAssertEqual(byteCount, 3)
    }

    func testInjectedFailureIsPreservedByCanonicalReadResult() async {
        let owner = PasteboardProviderOperationOwner(
            maximumConcurrentOperations: 1,
            maximumQueuedOperations: 0
        )
        let result = await owner.readData(
            maximumBytes: 8,
            timeout: 1,
            materialize: { _ in .failed }
        )

        XCTAssertEqual(result, .failed)
    }
    func testNativeFileURLReadRejectsOverLimitMaterializedData() async {
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(Data([1, 2, 3]), forType: .fileURL))

        let result = await SystemPasteboardFileURLReader().readFileURLData(
            from: item,
            maximumBytes: 2,
            timeout: 1
        )
        XCTAssertEqual(result, .tooLarge(byteCount: 3))
    }

    func testDefaultFileURLReaderMaterializesNamedPasteboard() async {
        let expectedURL = URL(fileURLWithPath: "/tmp/native-materialization.webp")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(expectedURL.absoluteString, forType: .fileURL))

        let result = await PasteboardSnapshot.exactFileURL(
            from: pasteboard,
            maximumItems: 1,
            maximumTypesPerItem: 1
        )
        XCTAssertEqual(result, expectedURL.standardizedFileURL)
    }

    func testNativeFileURLProviderReturnsAtDeadlineWhileProviderContinues() async {
        let finished = expectation(description: "Native file URL provider finished")
        let provider = PasteboardSnapshotBlockingDataProvider(
            data: Data("file:///tmp/target.webp".utf8),
            finished: finished
        )
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [.fileURL]))
        defer { provider.release.signal() }

        let result = await SystemPasteboardFileURLReader().readFileURLData(
            from: item,
            maximumBytes: PasteboardSnapshot.maximumFileURLBytes,
            timeout: 0.01
        )
        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(provider.invocationCount, 1)
        provider.release.signal()
        await fulfillment(of: [finished], timeout: 1)
    }

    func testBlockedMaterializerDoesNotBlockOtherOwnerWork() async {
        let owner = PasteboardProviderOperationOwner(
            maximumConcurrentOperations: 2,
            maximumQueuedOperations: 0
        )
        let blocked = PasteboardProviderBlockingMaterializer(
            data: Data([1]),
            expectedInvocationCount: 1
        )
        defer { blocked.release.signal() }

        let blockedRead = Task { @MainActor in
            await owner.readData(
                maximumBytes: 8,
                timeout: 10,
                materialize: { isActive in blocked.materialize(isActive) }
            )
        }
        await fulfillment(of: [blocked.started], timeout: 1)

        let fastResult = await owner.readData(
            maximumBytes: 8,
            timeout: 1,
            materialize: { _ in .data(Data([1, 2, 3])) }
        )
        guard case let .data(data) = fastResult else {
            return XCTFail("Expected independent owner work to complete")
        }
        XCTAssertEqual(data, Data([1, 2, 3]))

        blocked.release.signal()
        guard case .data = await blockedRead.value else {
            return XCTFail("Expected blocked materializer to complete")
        }
    }

    func testQueueCapRejectsExcessWorkWithoutInvokingMaterializer() async {
        let owner = PasteboardProviderOperationOwner(
            maximumConcurrentOperations: 1,
            maximumQueuedOperations: 0
        )
        let firstMaterializer = PasteboardProviderBlockingMaterializer(
            data: Data([1]),
            expectedInvocationCount: 1
        )
        let secondMaterializer = PasteboardProviderBlockingMaterializer(
            data: Data([2]),
            expectedInvocationCount: 1
        )
        secondMaterializer.release.signal()
        defer {
            firstMaterializer.release.signal()
            secondMaterializer.release.signal()
        }

        let firstRead = Task { @MainActor in
            await owner.readData(
                maximumBytes: 8,
                timeout: 10,
                materialize: { isActive in firstMaterializer.materialize(isActive) }
            )
        }
        await fulfillment(of: [firstMaterializer.started], timeout: 1)

        let secondResult = await owner.readData(
            maximumBytes: 8,
            timeout: 1,
            materialize: { isActive in secondMaterializer.materialize(isActive) }
        )
        guard case .unavailable = secondResult else {
            return XCTFail("Expected excess work to be rejected by the queue cap")
        }
        XCTAssertEqual(secondMaterializer.invocationCount, 0)

        firstMaterializer.release.signal()
        guard case .data = await firstRead.value else {
            return XCTFail("Expected active work to complete after release")
        }
    }

    func testInjectedOversizedMaterializationReleasesCapacity() async {
        let owner = PasteboardProviderOperationOwner(
            maximumConcurrentOperations: 1,
            maximumQueuedOperations: 0
        )
        let result = await owner.readData(
            maximumBytes: 2,
            timeout: 1,
            materialize: { _ in .data(Data([1, 2, 3])) }
        )
        guard case let .tooLarge(byteCount) = result else {
            return XCTFail("Expected oversized materialization")
        }
        XCTAssertEqual(byteCount, 3)

        let followUp = await owner.readData(
            maximumBytes: 2,
            timeout: 1,
            materialize: { _ in .data(Data([4])) }
        )
        guard case let .data(data) = followUp else {
            return XCTFail("Expected capacity to be released after rejection")
        }
        XCTAssertEqual(data, Data([4]))
    }

    func testRepeatedCancellationQuarantinesOnlyFixedCapacity() async {
        let owner = PasteboardProviderOperationOwner(
            maximumConcurrentOperations: 2,
            maximumQueuedOperations: 2
        )
        let materializer = PasteboardProviderBlockingMaterializer(
            data: Data([1]),
            expectedInvocationCount: 2
        )
        defer {
            materializer.release.signal()
            materializer.release.signal()
        }

        let tasks = (0..<4).map { _ in
            Task { @MainActor in
                await owner.readData(
                    maximumBytes: 8,
                    timeout: 10,
                    materialize: { isActive in
                        materializer.materialize(isActive)
                    }
                )
            }
        }
        await fulfillment(of: [materializer.started], timeout: 1)
        XCTAssertEqual(materializer.invocationCount, 2)

        tasks.forEach { $0.cancel() }
        for task in tasks {
            let result = await task.value
            guard case .cancelled = result else {
                return XCTFail("Expected cancellation result, got \(result)")
            }
        }

        let timedOut = await owner.readData(
            maximumBytes: 8,
            timeout: 1,
            materialize: { _ in .data(Data([2])) }
        )
        guard case .timedOut = timedOut else {
            return XCTFail("Expected bounded queue timeout while calls are quarantined")
        }
        XCTAssertEqual(materializer.invocationCount, 2)

        materializer.release.signal()
        materializer.release.signal()
        await fulfillment(of: [materializer.finished], timeout: 1)

        var recovered: PasteboardProviderOperationResult = .unavailable
        for _ in 0..<100 {
            recovered = await owner.readData(
                maximumBytes: 8,
                timeout: 1,
                materialize: { _ in .data(Data([3])) }
            )
            if case .data = recovered { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard case let .data(data) = recovered else {
            return XCTFail("Expected quarantined operations to release capacity")
        }
        XCTAssertEqual(data, Data([3]))
    }

    func testCaptureDiscardsLateFileURLResultAfterCancellation() async {
        let target = URL(fileURLWithPath: "/tmp/late.webp")
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(target.absoluteString, forType: .fileURL))
        let pasteboard = PasteboardSnapshotFakePasteboard(items: [item])
        let reader = PasteboardSnapshotBlockingFileURLReader()
        let capture = Task { @MainActor in
            await ClipboardWebPPasteboardCapture.captureImage(
                from: pasteboard,
                fileURLReader: reader
            )
        }

        await fulfillment(of: [reader.started], timeout: 1)
        capture.cancel()
        reader.resume(.data(Data(target.absoluteString.utf8)))

        let captureResult = await capture.value
        guard case .stale = captureResult else {
            return XCTFail("Expected cancellation to discard the capture")
        }
        XCTAssertEqual(reader.readCount, 1)
    }
}
