import AppKit
import XCTest

@MainActor
final class ClipboardWorkerTests: XCTestCase {
    func testImageWorkerReplacesPendingWorkAndKeepsOneActiveOperation() async {
        let gate = BlockingGate()
        let probe = BackgroundWorkProbe()
        let template = makeImageEnrichmentTemplate()
        let worker = ClipboardImageEnrichmentWorker { request, _ in
            let id = Int(request.generation)
            probe.begin(id)
            if id == 1 {
                gate.wait()
            }
            probe.end(id)
            return ClipboardImageEnrichment(
                generation: request.generation,
                kind: request.kind,
                thumbnail: template.thumbnail,
                imageFooter: nil
            )
        }
        var completedGenerations: [UInt64] = []

        worker.enqueue(makeImageRequest(generation: 1)) { enrichment in
            completedGenerations.append(enrichment.generation)
        }
        await waitUntil { probe.startedIDs == [1] }
        worker.enqueue(makeImageRequest(generation: 2)) { enrichment in
            completedGenerations.append(enrichment.generation)
        }
        worker.enqueue(makeImageRequest(generation: 3)) { enrichment in
            completedGenerations.append(enrichment.generation)
        }

        gate.open()
        await waitUntil { completedGenerations == [1, 3] }

        XCTAssertEqual(probe.startedIDs, [1, 3])
        XCTAssertEqual(probe.maximumActiveCount, 1)
        XCTAssertEqual(completedGenerations, [1, 3])
    }

    func testImageWorkerSuppressesResultsAfterCancellation() async {
        let gate = BlockingGate()
        let probe = BackgroundWorkProbe()
        let template = makeImageEnrichmentTemplate()
        let worker = ClipboardImageEnrichmentWorker { request, _ in
            let id = Int(request.generation)
            probe.begin(id)
            gate.wait()
            probe.end(id)
            return ClipboardImageEnrichment(
                generation: request.generation,
                kind: request.kind,
                thumbnail: template.thumbnail,
                imageFooter: nil
            )
        }
        var completedGenerations: [UInt64] = []

        worker.enqueue(makeImageRequest(generation: 1)) { enrichment in
            completedGenerations.append(enrichment.generation)
        }
        await waitUntil { probe.startedIDs == [1] }
        worker.enqueue(makeImageRequest(generation: 2)) { enrichment in
            completedGenerations.append(enrichment.generation)
        }
        worker.cancelAll()

        gate.open()
        await waitUntil { probe.finishedCount == 1 }
        await Task.yield()

        XCTAssertEqual(probe.startedIDs, [1])
        XCTAssertEqual(probe.maximumActiveCount, 1)
        XCTAssertTrue(completedGenerations.isEmpty)
    }

    func testCoordinatorUsesCapturedCancellationGenerationAfterCancelAllBeforePerform() async {
        let gate = CoordinatorInterleavingGate()
        let probe = BackgroundWorkProbe()
        let coordinator = ClipboardBackgroundWorkCoordinator<Int, Int>(
            label: "com.lycaennaa.sidekick.clipboard-coordinator-test",
            beforePerform: {
                gate.pause()
            }
        )

        DispatchQueue.global().async {
            coordinator.enqueue(
                1,
                operation: { _, isCancelled in
                    let cancelled = isCancelled()
                    probe.begin(cancelled ? 1 : 0)
                    probe.end(cancelled ? 1 : 0)
                    return nil
                },
                onResult: { _, _ in }
            )
        }

        await waitUntil { gate.hasReachedBeforePerform }
        coordinator.cancelAll()
        gate.allowPerform()

        await waitUntil { probe.finishedCount == 1 }

        XCTAssertEqual(probe.startedIDs, [1])
    }

    func testImageWorkerStartsReplacementWhileCancelledNativeOperationFinishes() async {
        let gate = BlockingGate()
        let probe = BackgroundWorkProbe()
        let template = makeImageEnrichmentTemplate()
        let worker = ClipboardImageEnrichmentWorker { request, _ in
            let id = Int(request.generation)
            probe.begin(id)
            if id == 1 {
                gate.wait()
            }
            probe.end(id)
            return ClipboardImageEnrichment(
                generation: request.generation,
                kind: request.kind,
                thumbnail: template.thumbnail,
                imageFooter: nil
            )
        }
        var completedGenerations: [UInt64] = []

        worker.enqueue(makeImageRequest(generation: 1)) { enrichment in
            completedGenerations.append(enrichment.generation)
        }
        await waitUntil { probe.startedIDs == [1] }
        worker.cancelAll()
        worker.enqueue(makeImageRequest(generation: 2)) { enrichment in
            completedGenerations.append(enrichment.generation)
        }

        await waitUntil { probe.startedIDs == [1, 2] }
        XCTAssertEqual(probe.maximumActiveCount, 2)

        gate.open()
        await waitUntil { probe.finishedCount == 2 }
        XCTAssertEqual(completedGenerations, [2])
    }

    func testWebPWorkerStartsReplacementWhileCancelledNativeOperationFinishes() async {
        let gate = BlockingGate()
        let probe = BackgroundWorkProbe()
        let worker = ClipboardImageConversionWorker { source, outputDirectory in
            let id = clipboardWorkerID(source)
            probe.begin(id)
            if id == 1 {
                gate.wait()
            }
            probe.end(id)
            return outputDirectory.appendingPathComponent("\(id).webp")
        }
        let outputDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var successfulIDs: [Int] = []
        var cancelledIDs: [Int] = []
        var cleanedIDs: [Int] = []

        func enqueue(_ id: Int) {
            worker.enqueue(
                source: clipboardWorkerSource(id),
                outputDirectory: outputDirectory,
                cleanup: { _ in cleanedIDs.append(id) },
                completion: { result in
                    switch result {
                    case .success:
                        successfulIDs.append(id)
                    case .cancelled:
                        cancelledIDs.append(id)
                    case .failure:
                        XCTFail("Unexpected WebP conversion failure")
                    }
                }
            )
        }

        enqueue(1)
        await waitUntil { probe.startedIDs == [1] }
        worker.cancelAll()
        enqueue(2)

        await waitUntil { probe.startedIDs == [1, 2] }
        XCTAssertEqual(probe.maximumActiveCount, 2)

        gate.open()
        await waitUntil { successfulIDs == [2] && cleanedIDs == [1] }
        XCTAssertEqual(cancelledIDs, [1])
    }

    func testWebPWorkerReplacesPendingWorkAndKeepsOneActiveOperation() async {
        let gate = BlockingGate()
        let probe = BackgroundWorkProbe()
        let worker = ClipboardImageConversionWorker { source, outputDirectory in
            let id = clipboardWorkerID(source)
            probe.begin(id)
            if id == 1 {
                gate.wait()
            }
            probe.end(id)
            return outputDirectory.appendingPathComponent("\(id).webp")
        }
        let outputDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var successfulIDs: [Int] = []
        var cancelledIDs: [Int] = []
        var cleanedIDs: [Int] = []

        func enqueue(_ id: Int) {
            worker.enqueue(
                source: clipboardWorkerSource(id),
                outputDirectory: outputDirectory,
                cleanup: { _ in cleanedIDs.append(id) },
                completion: { result in
                    switch result {
                    case .success:
                        successfulIDs.append(id)
                    case .cancelled:
                        cancelledIDs.append(id)
                    case .failure:
                        XCTFail("Unexpected WebP conversion failure")
                    }
                }
            )
        }

        enqueue(1)
        await waitUntil { probe.startedIDs == [1] }
        enqueue(2)
        enqueue(3)
        await waitUntil { cancelledIDs == [2] }

        gate.open()
        await waitUntil { successfulIDs == [1, 3] }

        XCTAssertEqual(probe.startedIDs, [1, 3])
        XCTAssertEqual(probe.maximumActiveCount, 1)
        XCTAssertEqual(successfulIDs, [1, 3])
        XCTAssertEqual(cancelledIDs, [2])
        XCTAssertTrue(cleanedIDs.isEmpty)
    }

    func testWebPWorkerCancelsPendingAndCleansLateActiveResult() async {
        let gate = BlockingGate()
        let probe = BackgroundWorkProbe()
        let worker = ClipboardImageConversionWorker { source, outputDirectory in
            let id = clipboardWorkerID(source)
            probe.begin(id)
            gate.wait()
            probe.end(id)
            return outputDirectory.appendingPathComponent("\(id).webp")
        }
        let outputDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var successfulIDs: [Int] = []
        var cancelledIDs: [Int] = []
        var cleanedIDs: [Int] = []

        func enqueue(_ id: Int) {
            worker.enqueue(
                source: clipboardWorkerSource(id),
                outputDirectory: outputDirectory,
                cleanup: { _ in cleanedIDs.append(id) },
                completion: { result in
                    switch result {
                    case .success:
                        successfulIDs.append(id)
                    case .cancelled:
                        cancelledIDs.append(id)
                    case .failure:
                        XCTFail("Unexpected WebP conversion failure")
                    }
                }
            )
        }

        enqueue(1)
        await waitUntil { probe.startedIDs == [1] }
        enqueue(2)
        worker.cancelAll()
        await waitUntil { cancelledIDs == [1, 2] }

        gate.open()
        await waitUntil { cleanedIDs == [1] }

        XCTAssertEqual(probe.startedIDs, [1])
        XCTAssertEqual(probe.maximumActiveCount, 1)
        XCTAssertTrue(successfulIDs.isEmpty)
        XCTAssertEqual(cancelledIDs, [1, 2])
        XCTAssertEqual(cleanedIDs, [1])
    }

    func testWebPWorkerStopsActiveConversionAtCancellationCheckpoint() async {
        let started = expectation(description: "Active WebP conversion started")
        let worker = ClipboardImageConversionWorker(convert: { source, outputDirectory, _, isCancelled in
            let id = clipboardWorkerID(source)
            if id == 1 {
                started.fulfill()
                while !isCancelled() {
                    Thread.sleep(forTimeInterval: 0.001)
                }
                throw CancellationError()
            }
            return outputDirectory.appendingPathComponent("\(id).webp")
        })
        let outputDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var firstCancelled = false
        var secondSucceeded = false

        func enqueue(_ id: Int) {
            worker.enqueue(
                source: clipboardWorkerSource(id),
                outputDirectory: outputDirectory,
                cleanup: { _ in },
                completion: { result in
                    if id == 1, case .cancelled = result {
                        firstCancelled = true
                    }
                    if id == 2, case .success = result {
                        secondSucceeded = true
                    }
                }
            )
        }

        enqueue(1)
        await fulfillment(of: [started], timeout: 1)
        worker.cancelAll()
        enqueue(2)

        await waitUntil { firstCancelled && secondSucceeded }
        XCTAssertTrue(firstCancelled)
        XCTAssertTrue(secondSucceeded)
    }

    private func makeImageRequest(generation: UInt64) -> ClipboardImageEnrichmentRequest {
        ClipboardImageEnrichmentRequest(
            generation: generation,
            data: Data([0]),
            typeIdentifier: NSPasteboard.PasteboardType.png.rawValue
        )
    }

    private func makeImageEnrichmentTemplate() -> ClipboardImageEnrichment {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 1,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ), let thumbnail = bitmap.cgImage else {
            fatalError("Could not create test image")
        }
        return ClipboardImageEnrichment(
            generation: 0,
            kind: .data,
            thumbnail: thumbnail,
            imageFooter: nil
        )
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Condition was not met", file: file, line: line)
    }
}

private func clipboardWorkerSource(_ id: Int) -> ClipboardImageSource {
    .data(Data([UInt8(id)]))
}

private func clipboardWorkerID(_ source: ClipboardImageSource) -> Int {
    guard case let .data(data) = source, let id = data.first else { return -1 }
    return Int(id)
}

private final class BackgroundWorkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var started: [Int] = []
    private var finished = 0
    private var maximumActive = 0

    var startedIDs: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    var finishedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var maximumActiveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActive
    }

    func begin(_ id: Int) {
        lock.lock()
        activeCount += 1
        maximumActive = max(maximumActive, activeCount)
        started.append(id)
        lock.unlock()
    }

    func end(_ id: Int) {
        lock.lock()
        activeCount -= 1
        finished += 1
        lock.unlock()
    }
}

private final class BlockingGate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func wait() {
        semaphore.wait()
    }

    func open() {
        semaphore.signal()
    }
}

private final class CoordinatorInterleavingGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func pause() {
        entered.signal()
        release.wait()
    }

    var hasReachedBeforePerform: Bool {
        entered.wait(timeout: .now()) == .success
    }

    func allowPerform() {
        release.signal()
    }
}
