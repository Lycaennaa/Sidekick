import AppKit
import XCTest

@MainActor
final class ClipboardToastControllerTests: XCTestCase {
    func testPollRequiresStableSecondSampleAndEmitsCompleteTransition() async {
        let context = makeContext(source: .init(name: "Safari", bundleIdentifier: "com.apple.Safari"))
        setText("baseline", on: context.pasteboard)
        context.controller.start()

        setText("next", on: context.pasteboard)
        context.controller.poll()
        XCTAssertTrue(context.toasts.isEmpty)

        context.controller.poll()
        await drainAsyncWork()
        XCTAssertEqual(context.toasts.last??.summary, "next")
        let footer = context.toasts.last??.footer
        XCTAssertTrue(footer?.contains("1 word") == true)
        XCTAssertTrue(footer?.contains("4 characters") == true)
        XCTAssertTrue(footer?.contains("1 token") == true)
        XCTAssertTrue(footer?.contains("Copied from Safari") == true)
        context.controller.terminate()
    }
    func testDefaultProductionDependenciesPresentNamedPasteboardToastContext() async {
        let suite = "ClipboardToastIntegration-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Unable to create test defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipboardToastIntegration-\(UUID().uuidString)")
        )
        let workspaceNotifications = NotificationCenter()
        let toastPresented = expectation(description: "Default clipboard toast presented")
        var toast: ToastModel?
        let controller = ClipboardToastController(
            settings: settings,
            pasteboard: pasteboard,
            sourceApplication: {
                ClipboardSourceApplication(
                    name: "Integration App",
                    bundleIdentifier: "com.example.clipboard-integration"
                )
            },
            workspaceNotificationCenter: workspaceNotifications,
            onToastChange: { model in
                guard let model else { return }
                toast = model
                toastPresented.fulfill()
            }
        )
        defer {
            controller.terminate()
            pasteboard.clearContents()
            defaults.removePersistentDomain(forName: suite)
        }

        setText("baseline", on: pasteboard)
        controller.start()
        setText("hello world", on: pasteboard)
        controller.poll()
        controller.poll()

        await fulfillment(of: [toastPresented], timeout: 5)

        XCTAssertEqual(toast?.presentationStyle, .text)
        XCTAssertEqual(toast?.summary, "hello world")
        XCTAssertEqual(
            toast?.footer,
            "2 words • 11 characters • 2 tokens • Copied from Integration App"
        )
    }

    func testStableTextPayloadReadsExternalProviderOnce() async {
        let reader = ControlledPayloadReader()
        let context = makeContext(
            source: .init(name: "App", bundleIdentifier: "test.app"),
            payloadReader: reader
        )
        setText("baseline", on: context.pasteboard)
        context.controller.start()
        await fulfillment(of: [reader.initialReadStarted], timeout: 1)
        await drainAsyncWork()

        let readsBeforeChange = reader.readCount
        setText("next", on: context.pasteboard)
        context.controller.poll()
        context.controller.poll()
        await drainAsyncWork()

        XCTAssertEqual(reader.readCount - readsBeforeChange, 1)
        XCTAssertEqual(context.toasts.last??.summary, "next")
        context.controller.terminate()
    }

    func testSourceChangeDropsAttributionAndExclusionSuppressesToast() async {
        let source = SourceBox(.init(name: "Safari", bundleIdentifier: "com.apple.Safari"))
        let context = makeContext(sourceBox: source)
        setText("baseline", on: context.pasteboard)
        context.controller.start()

        source.value = .init(name: "Finder", bundleIdentifier: "com.apple.finder")
        context.workspaceNotifications.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        setText("after switch", on: context.pasteboard)
        context.controller.poll()
        context.controller.poll()
        await drainAsyncWork()
        let footer = context.toasts.last??.footer
        XCTAssertTrue(footer?.contains("2 words") == true)
        XCTAssertFalse(footer?.contains("Copied from") == true)

        context.settings.excludedToastApplicationBundleIdentifiers = ["com.apple.finder"]
        setText("excluded", on: context.pasteboard)
        context.controller.poll()
        context.controller.poll()
        await drainAsyncWork()
        XCTAssertNil(context.toasts.last.flatMap(\.self))
        context.controller.terminate()
    }

    func testTransientClipboardRestoreNeverReplaysBaselineToast() async {
        let context = makeContext(source: .init(name: "App", bundleIdentifier: "test.app"))
        setText("baseline", on: context.pasteboard)
        context.controller.start()
        await drainAsyncWork()
        context.pasteboard.clearContents()
        context.pasteboard.clearContents()
        let transient = NSPasteboardItem()
        transient.setString("temporary", forType: .string)
        transient.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
        context.pasteboard.writeObjects([transient])
        context.controller.poll()

        setText("baseline", on: context.pasteboard)
        context.controller.poll()
        context.controller.poll()
        await drainAsyncWork()

        XCTAssertTrue(context.toasts.isEmpty)
        context.controller.terminate()
    }

    func testSourceChangeInvalidatesPendingImageEnrichment() async throws {
        let worker = ControlledImageWorker()
        let context = makeContext(
            source: .init(name: "App", bundleIdentifier: "test.app"),
            imageWorker: worker
        )
        setText("baseline", on: context.pasteboard)
        context.controller.start()
        setPNG(Data([1, 2, 3]), on: context.pasteboard)
        context.controller.poll()
        context.controller.poll()
        await drainAsyncWork()
        let request = try XCTUnwrap(worker.lastRequest)
        XCTAssertEqual(context.toasts.last??.presentationStyle, .image)

        XCTAssertEqual(context.toasts.last??.footer, "3 bytes\nCopied from App")
        setText("newer", on: context.pasteboard)
        context.controller.poll()
        worker.complete(
            ClipboardImageEnrichment(
                generation: request.generation,
                kind: request.kind,
                thumbnail: try makePixel(),
                imageFooter: "stale"
            )
        )
        XCTAssertTrue(context.updates.isEmpty)

        context.controller.poll()
        await drainAsyncWork()
        XCTAssertEqual(context.toasts.last??.presentationStyle, .text)
        XCTAssertGreaterThanOrEqual(worker.cancellationCount, 2)
        context.controller.terminate()
    }
    func testImageEnrichmentKeepsClipboardSourceAttribution() async throws {
        let worker = ControlledImageWorker()
        let context = makeContext(
            source: .init(name: "App", bundleIdentifier: "test.app"),
            imageWorker: worker
        )
        setText("baseline", on: context.pasteboard)
        context.controller.start()
        setPNG(Data([1, 2, 3]), on: context.pasteboard)
        context.controller.poll()
        context.controller.poll()
        await drainAsyncWork()
        let request = try XCTUnwrap(worker.lastRequest)

        XCTAssertEqual(context.toasts.last??.footer, "3 bytes\nCopied from App")
        worker.complete(
            ClipboardImageEnrichment(
                generation: request.generation,
                kind: request.kind,
                thumbnail: try makePixel(),
                imageFooter: "4 × 4 • PNG"
            )
        )

        XCTAssertEqual(context.updates.last?.footer, "4 × 4 • PNG\nCopied from App")
        context.controller.terminate()
    }

    func testFileToastPreservesClipboardSourceAttribution() async {
        let context = makeContext(source: .init(name: "Finder", bundleIdentifier: "com.apple.finder"))
        setText("baseline", on: context.pasteboard)
        context.controller.start()

        context.pasteboard.clearContents()
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString(
            URL(fileURLWithPath: "/missing/report.txt").absoluteString,
            forType: .fileURL
        ))
        XCTAssertTrue(context.pasteboard.writeObjects([item]))
        context.controller.poll()
        context.controller.poll()
        await drainAsyncWork()

        XCTAssertEqual(context.toasts.last??.presentationStyle, .files)
        XCTAssertEqual(context.toasts.last??.summary, "Copied report.txt")
        XCTAssertEqual(context.toasts.last??.footer, "Copied from Finder")
        context.controller.terminate()
    }
    func testDismissalInvalidatesPendingPayloadPublication() async {
        let (context, reader) = await makePendingPayload()

        context.controller.dismissCurrentToast()
        reader.resumeBlockedRead()
        await drainAsyncWork()

        XCTAssertTrue(context.toasts.isEmpty)
        context.controller.terminate()
    }

    func testUtilityOperationInvalidatesPendingPayloadPublication() async {
        let (context, reader) = await makePendingPayload()

        context.controller.cancelPendingPayloadOperation()
        reader.resumeBlockedRead()
        await drainAsyncWork()

        XCTAssertTrue(context.toasts.isEmpty)
        context.controller.terminate()
    }

    func testAcknowledgmentInvalidatesPendingPayloadPublication() async {
        let (context, reader) = await makePendingPayload()

        context.controller.acknowledgeClipboardChange(context.pasteboard.changeCount)
        reader.resumeBlockedRead()
        await drainAsyncWork()

        XCTAssertTrue(context.toasts.isEmpty)
        context.controller.terminate()
    }

    private func makePendingPayload() async -> (Context, ControlledPayloadReader) {
        let reader = ControlledPayloadReader()
        let context = makeContext(
            source: .init(name: "App", bundleIdentifier: "test.app"),
            payloadReader: reader
        )
        setText("baseline", on: context.pasteboard)
        context.controller.start()
        await fulfillment(of: [reader.initialReadStarted], timeout: 1)
        await drainAsyncWork()

        reader.blockNextRead()
        setText("next", on: context.pasteboard)
        context.controller.poll()
        context.controller.poll()
        await fulfillment(of: [reader.blockedReadStarted], timeout: 1)
        return (context, reader)
    }

    private func drainAsyncWork() async {
        for _ in 0..<64 {
            await Task.yield()
        }
    }
    private func makeContext(
        source: ClipboardSourceApplication,
        imageWorker: any ClipboardImageEnriching = ControlledImageWorker(),
        payloadReader: any PasteboardPayloadReading = InlinePasteboardPayloadReader()
    ) -> Context {
        makeContext(
            sourceBox: SourceBox(source),
            imageWorker: imageWorker,
            payloadReader: payloadReader
        )
    }

    private func makeContext(
        sourceBox: SourceBox,
        imageWorker: any ClipboardImageEnriching = ControlledImageWorker(),
        payloadReader: any PasteboardPayloadReading = InlinePasteboardPayloadReader()
    ) -> Context {
        let suite = "ClipboardToastControllerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("Unable to create test defaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        let pasteboard = NSPasteboard(name: .init("ClipboardToastControllerTests.\(UUID().uuidString)"))
        let workspaceNotifications = NotificationCenter()
        let recorder = ToastRecorder()
        let controller = ClipboardToastController(
            settings: settings,
            pasteboard: pasteboard,
            sourceApplication: { sourceBox.value },
            workspaceNotificationCenter: workspaceNotifications,
            imageWorker: imageWorker,
            fileURLReader: InlinePasteboardFileURLReader(),
            payloadReader: payloadReader,
            onToastChange: { recorder.toasts.append($0) },
            onToastUpdate: { recorder.updates.append($0) }
        )
        return Context(
            settings: settings,
            pasteboard: pasteboard,
            workspaceNotifications: workspaceNotifications,
            controller: controller,
            recorder: recorder
        )
    }

    private func setText(_ text: String, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        pasteboard.writeObjects([item])
    }

    private func setPNG(_ data: Data, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        pasteboard.writeObjects([item])
    }

    private func makePixel() throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        return try XCTUnwrap(context.makeImage())
    }

    @MainActor
    private final class Context {
        let settings: AppSettings
        let pasteboard: NSPasteboard
        let workspaceNotifications: NotificationCenter
        let controller: ClipboardToastController
        private let recorder: ToastRecorder
        var toasts: [ToastModel?] { recorder.toasts }
        var updates: [ToastModel] { recorder.updates }

        init(
            settings: AppSettings,
            pasteboard: NSPasteboard,
            workspaceNotifications: NotificationCenter,
            controller: ClipboardToastController,
            recorder: ToastRecorder
        ) {
            self.settings = settings
            self.pasteboard = pasteboard
            self.workspaceNotifications = workspaceNotifications
            self.controller = controller
            self.recorder = recorder
        }
    }
}

@MainActor
private final class ToastRecorder {
    var toasts: [ToastModel?] = []
    var updates: [ToastModel] = []
}

private final class SourceBox: @unchecked Sendable {
    var value: ClipboardSourceApplication

    init(_ value: ClipboardSourceApplication) {
        self.value = value
    }
}

private final class ControlledImageWorker: ClipboardImageEnriching, @unchecked Sendable {
    private let lock = NSLock()
    private var request: ClipboardImageEnrichmentRequest?
    private var completion: ClipboardImageEnrichmentCompletion?
    private var cancellations = 0

    var lastRequest: ClipboardImageEnrichmentRequest? {
        lock.withLock { request }
    }

    var cancellationCount: Int {
        lock.withLock { cancellations }
    }

    func enqueue(
        _ request: ClipboardImageEnrichmentRequest,
        completion: @escaping ClipboardImageEnrichmentCompletion
    ) {
        lock.withLock {
            self.request = request
            self.completion = completion
        }
    }

    func cancelAll() {
        lock.withLock { cancellations += 1 }
    }

    @MainActor
    func complete(_ enrichment: ClipboardImageEnrichment) {
        lock.withLock { completion }?(enrichment)
    }
}
@MainActor
private final class ControlledPayloadReader: PasteboardPayloadReading {
    let initialReadStarted = XCTestExpectation(description: "Initial clipboard payload read started")
    let blockedReadStarted = XCTestExpectation(description: "Blocked clipboard payload read started")
    private(set) var readCount = 0
    private var shouldBlockNextRead = false
    private var initialReadReported = false
    private var continuation: CheckedContinuation<PasteboardPayloadReader.Result, Never>?
    private var blockedResult: PasteboardPayloadReader.Result?

    func blockNextRead() {
        shouldBlockNextRead = true
    }

    func readData(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType,
        maximumBytes: Int
    ) async -> PasteboardPayloadReader.Result {
        readCount += 1
        guard let data = item.data(forType: type) else { return .missing }
        guard data.count <= maximumBytes else {
            return .tooLarge(byteCount: data.count)
        }

        let result = PasteboardPayloadReader.Result.data(data)
        if shouldBlockNextRead {
            shouldBlockNextRead = false
            blockedResult = result
            blockedReadStarted.fulfill()
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        if !initialReadReported {
            initialReadReported = true
            initialReadStarted.fulfill()
        }
        return result
    }

    func resumeBlockedRead() {
        let continuation = self.continuation
        self.continuation = nil
        let result = blockedResult ?? .missing
        blockedResult = nil
        continuation?.resume(returning: result)
    }
}
