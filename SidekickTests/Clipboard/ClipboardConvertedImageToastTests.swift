import AppKit
import XCTest

@MainActor
private final class ClipboardToastPresentationRecorder {
    let coordinator: ToastPresentationCoordinator
    let visibleFrame: CGRect
    let copiedToastPresented: XCTestExpectation
    var generalToastID: ToastPresentationCoordinator.ID?
    var copiedToastModel: ToastModel?

    init(
        coordinator: ToastPresentationCoordinator,
        visibleFrame: CGRect,
        copiedToastPresented: XCTestExpectation
    ) {
        self.coordinator = coordinator
        self.visibleFrame = visibleFrame
        self.copiedToastPresented = copiedToastPresented
    }

    func handle(_ model: ToastModel?) {
        guard let model else {
            coordinator.hideGeneral()
            generalToastID = nil
            return
        }
        copiedToastModel = model
        generalToastID = coordinator.presentGeneral(
            model,
            duration: .infinity,
            visibleFrame: visibleFrame
        )
        if model.summary == "Copied image" {
            copiedToastPresented.fulfill()
        }
    }
}

@MainActor
private struct ClipboardConvertedImageToastFixture {
    let suite: String
    let defaults: UserDefaults
    let pasteboard: NSPasteboard
    let controller: ClipboardToastController
    let toastStack: ToastStackController
    let toastCoordinator: ToastPresentationCoordinator
    let recorder: ClipboardToastPresentationRecorder
    let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 800)

    init() throws {
        suite = "ClipboardConvertedImageToast.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        pasteboard = NSPasteboard(name: .init("ClipboardConvertedImageToast.\(UUID().uuidString)"))
        toastStack = ToastStackController()
        toastCoordinator = ToastPresentationCoordinator(stack: toastStack)
        let copiedToastPresented = XCTestExpectation(description: "Copied-image toast presented")
        recorder = ClipboardToastPresentationRecorder(
            coordinator: toastCoordinator,
            visibleFrame: visibleFrame,
            copiedToastPresented: copiedToastPresented
        )
        controller = ClipboardToastController(
            settings: settings,
            pasteboard: pasteboard,
            sourceApplication: {
                ClipboardSourceApplication(name: "Source App", bundleIdentifier: "com.example.source")
            },
            workspaceNotificationCenter: NotificationCenter(),
            onToastChange: recorder.handle
        )
    }

    func cleanup() {
        controller.terminate()
        toastCoordinator.hideGeneral()
        pasteboard.clearContents()
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
final class ClipboardConvertedImageToastTests: XCTestCase {
    func testAutomaticConversionReplacesMatchingClipboardImageToast() async throws {
        let fixture = try ClipboardConvertedImageToastFixture()
        defer { fixture.cleanup() }

        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("baseline", forType: .string))
        fixture.controller.start()
        fixture.pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        XCTAssertTrue(fixture.pasteboard.writeObjects([item]))
        let sourceChangeCount = fixture.pasteboard.changeCount
        fixture.controller.poll()
        fixture.controller.poll()
        await fulfillment(of: [fixture.recorder.copiedToastPresented], timeout: 5)

        let copiedToastID = try XCTUnwrap(fixture.recorder.generalToastID)
        XCTAssertEqual(fixture.recorder.copiedToastModel?.summary, "Copied image")
        XCTAssertTrue(fixture.toastStack.isPresented(copiedToastID))
        XCTAssertNil(fixture.controller.prepareCurrentToastReplacement(forChangeCount: sourceChangeCount + 1))
        let copiedToastGeneration = try XCTUnwrap(
            fixture.controller.prepareCurrentToastReplacement(forChangeCount: sourceChangeCount)
        )
        XCTAssertEqual(copiedToastGeneration, fixture.recorder.copiedToastModel?.generation)
        XCTAssertTrue(fixture.toastStack.isPresented(copiedToastID))

        let convertedURL = URL(fileURLWithPath: "/output/image.webp")
        let copyContext = ConvertedImageToastCopyContext.clipboardImage(
            sourceChangeCount: sourceChangeCount
        )
        let convertedModel = ConvertedImageToastPresentation.model(
            url: convertedURL,
            generation: 8,
            copyContext: copyContext,
            icon: NSImage(size: NSSize(width: 1, height: 1)),
            enrichment: nil
        )
        XCTAssertEqual(convertedModel.summary, "Image copied and converted to image.webp.")

        let convertedToastID = fixture.toastCoordinator.presentGeneral(
            convertedModel,
            duration: .infinity,
            visibleFrame: fixture.visibleFrame
        )
        XCTAssertEqual(convertedToastID, copiedToastID)
        XCTAssertTrue(fixture.toastStack.isPresented(copiedToastID))
        fixture.controller.toastDidDismiss(generation: copiedToastGeneration)
        XCTAssertFalse(fixture.controller.hasCurrentToast(generation: copiedToastGeneration))
        fixture.controller.dismissCurrentToast()
        XCTAssertTrue(fixture.toastStack.isPresented(copiedToastID))
    }

    func testAbandonedConversionStillAllowsCopiedToastToBeCleared() async throws {
        let fixture = try ClipboardConvertedImageToastFixture()
        defer { fixture.cleanup() }

        fixture.pasteboard.clearContents()
        XCTAssertTrue(fixture.pasteboard.setString("baseline", forType: .string))
        fixture.controller.start()
        fixture.pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        XCTAssertTrue(fixture.pasteboard.writeObjects([item]))
        let sourceChangeCount = fixture.pasteboard.changeCount
        fixture.controller.poll()
        fixture.controller.poll()
        await fulfillment(of: [fixture.recorder.copiedToastPresented], timeout: 5)

        let copiedToastID = try XCTUnwrap(fixture.recorder.generalToastID)
        let copiedToastGeneration = try XCTUnwrap(
            fixture.controller.prepareCurrentToastReplacement(forChangeCount: sourceChangeCount)
        )
        fixture.controller.dismissCurrentToast()

        XCTAssertFalse(fixture.toastStack.isPresented(copiedToastID))
        XCTAssertFalse(fixture.controller.hasCurrentToast(generation: copiedToastGeneration))
        XCTAssertNil(fixture.recorder.generalToastID)
    }
}
