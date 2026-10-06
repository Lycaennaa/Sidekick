import AppKit
import XCTest

@MainActor
final class ToastPanelControllerTests: XCTestCase {

    func testSummarySizeWrapsCopiedCommandWithoutChangingText() {
        let text = "Sidekick % buildxcodeprojv2 xcode build --scheme sidekick"
        let label = summaryLabel(text)
        let singleLineHeight = ToastPanelController.summarySize(
            for: summaryLabel("Text"),
            maximumSize: CGSize(width: 360, height: 318)
        ).height

        let size = ToastPanelController.summarySize(
            for: label,
            maximumSize: CGSize(width: 360, height: 318)
        )

        XCTAssertEqual(label.stringValue, text)
        XCTAssertGreaterThan(size.height, singleLineHeight)
        XCTAssertLessThanOrEqual(size.width, 360)
        XCTAssertLessThanOrEqual(size.height, 318)
    }

    func testSummarySizeBoundsWideTextWithoutPreTruncatingIt() {
        let text = String(repeating: "\u{FDFA}", count: 320)
        let label = summaryLabel(text)

        let size = ToastPanelController.summarySize(
            for: label,
            maximumSize: CGSize(width: 698, height: 318)
        )

        XCTAssertEqual(label.stringValue, text)
        XCTAssertLessThanOrEqual(size.width, 698)
        XCTAssertLessThanOrEqual(size.height, 318)
    }

    func testIconUsesCompactSizeWhileImagePreviewStays192Pixels() {
        XCTAssertEqual(
            ToastPanelController.displayedIconSize(hasIcon: true, showsImagePreview: false),
            96
        )
        XCTAssertEqual(
            ToastPanelController.displayedIconSize(hasIcon: true, showsImagePreview: true),
            192
        )
        XCTAssertEqual(
            ToastPanelController.displayedIconSize(hasIcon: false, showsImagePreview: true),
            0
        )
    }

    func testImageEnrichmentKeepsExpandedFrameAfterPresentationAnimation() {
        let controller = ToastPanelController(reduceMotion: { false })
        let compactModel = ToastModel(
            generation: 7,
            presentationStyle: .image,
            summary: "Copied image",
            detail: nil,
            icon: NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        )
        let previewModel = ToastModel(
            generation: 7,
            presentationStyle: .image,
            summary: "Copied image",
            detail: nil,
            icon: NSImage(size: NSSize(width: 384, height: 384)),
            showsImagePreview: true
        )

        controller.present(compactModel, duration: 1)
        let compactFrame = controller.presentedFrame
        controller.update(previewModel)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        XCTAssertGreaterThan(controller.presentedFrame.height, compactFrame.height)
        controller.hide()
    }

    func testDismissNotifiesOnceAndCancelsAutomaticDismissal() {
        var dismissedGenerations: [UInt64] = []
        let controller = ToastPanelController(
            onDismiss: { dismissedGenerations.append($0) },
            reduceMotion: { true }
        )
        controller.present(
            ToastModel(
                generation: 42,
                presentationStyle: .text,
                summary: "Copied text",
                detail: nil,
                icon: NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
            ),
            duration: 0.01
        )

        controller.dismiss()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(dismissedGenerations, [42])
        controller.hide()
    }

    func testInfiniteDurationRemainsVisibleUntilHidden() {
        let controller = ToastPanelController(reduceMotion: { true })
        controller.present(
            ToastModel.generic(generation: 1),
            duration: .infinity
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertTrue(controller.isVisible)
        controller.hide()
    }

    func testMicrophoneToastCanBeRecreatedAfterHiding() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        let model = ToastModel.generic(generation: 1)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 900)

        let firstID = try XCTUnwrap(coordinator.presentMicrophone(
            model,
            duration: .infinity,
            visibleFrame: visibleFrame
        ))
        XCTAssertTrue(stack.isPresented(firstID))

        coordinator.hideMicrophone()
        XCTAssertFalse(stack.contains(firstID))

        let secondID = try XCTUnwrap(coordinator.presentMicrophone(
            model,
            duration: .infinity,
            visibleFrame: visibleFrame
        ))
        XCTAssertTrue(stack.isPresented(secondID))
        XCTAssertNotEqual(firstID, secondID)
        coordinator.hideAll()
    }

    func testMicrophoneToastOutranksTwitchToastsWhenSpaceIsLimited() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 700)
        var twitchIDs: [ToastStackController.ID] = []

        for generation in 1...4 {
            if let id = coordinator.presentTwitch(
                ToastModel.generic(generation: UInt64(generation)),
                duration: 10,
                visibleFrame: visibleFrame
            ) {
                twitchIDs.append(id)
            }
        }
        let microphoneID = try XCTUnwrap(coordinator.presentMicrophone(
            ToastModel.generic(generation: 5),
            duration: .infinity,
            visibleFrame: visibleFrame
        ))

        XCTAssertTrue(stack.isPresented(microphoneID))
        XCTAssertTrue(twitchIDs.contains { stack.presentedFrame(for: $0) != nil })
        coordinator.hideAll()
    }

    func testGeneralDismissalPolicyReportsGenerationOnce() {
        var dismissedGenerations: [UInt64] = []
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        coordinator.presentGeneral(
            ToastModel.generic(generation: 9),
            duration: .infinity,
            onDismiss: { dismissedGenerations.append($0) }
        )

        coordinator.hideGeneral()
        coordinator.hideGeneral()

        XCTAssertEqual(dismissedGenerations, [9])
        coordinator.hideAll()
    }

    func testScreenshotAndClipboardToastsRemainVisibleTogether() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 900)
        let clipboardID = try XCTUnwrap(coordinator.presentGeneral(
            ToastModel.generic(generation: 1),
            duration: 10,
            visibleFrame: visibleFrame
        ))
        let screenshotID = try XCTUnwrap(coordinator.presentScreenshot(
            ToastModel.generic(generation: 2),
            duration: 10,
            visibleFrame: visibleFrame
        ))
        let replacementID = try XCTUnwrap(coordinator.presentScreenshot(
            ToastModel.generic(generation: 3),
            duration: 10,
            visibleFrame: visibleFrame
        ))

        XCTAssertEqual(replacementID, screenshotID)
        XCTAssertTrue(stack.isPresented(clipboardID))
        XCTAssertTrue(stack.isPresented(screenshotID))
        let clipboardFrame = try XCTUnwrap(stack.presentedFrame(for: clipboardID))
        let screenshotFrame = try XCTUnwrap(stack.presentedFrame(for: screenshotID))
        XCTAssertFalse(clipboardFrame.intersects(screenshotFrame))
        coordinator.hideAll()
    }

    func testToastStackKeepsMultipleToastsVisible() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 900)
        let firstID = try XCTUnwrap(coordinator.presentTwitch(
            ToastModel.generic(generation: 1),
            duration: 10,
            visibleFrame: visibleFrame
        ))
        let secondID = try XCTUnwrap(coordinator.presentTwitch(
            ToastModel.generic(generation: 2),
            duration: 10,
            visibleFrame: visibleFrame
        ))

        let firstFrame = try XCTUnwrap(stack.presentedFrame(for: firstID))
        let secondFrame = try XCTUnwrap(stack.presentedFrame(for: secondID))
        XCTAssertFalse(firstFrame.intersects(secondFrame))
        XCTAssertGreaterThanOrEqual(
            secondFrame.minY,
            firstFrame.maxY + ToastLayout.stackSpacing
        )

        coordinator.hideAll()
    }

    func testTwitchSlotUsesFixedCapacityAndReplacement() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 900)
        var ids: [ToastStackController.ID] = []

        for generation in 1...5 {
            ids.append(try XCTUnwrap(coordinator.presentTwitch(
                ToastModel.generic(generation: UInt64(generation)),
                duration: 10,
                visibleFrame: visibleFrame
            )))
        }

        XCTAssertFalse(stack.contains(ids[0]))
        XCTAssertTrue(ids.dropFirst().allSatisfy { stack.contains($0) })
        coordinator.hideAll()
    }

    func testToastStackAcceptsFeatureNeutralEntryConfiguration() throws {
        let stack = ToastStackController()
        let configuration = ToastStackEntryConfiguration(
            maximumSize: CGSize(width: 500, height: 240),
            layoutPriority: 7,
            preservesRecoverableToast: false
        )
        let id = try XCTUnwrap(stack.present(
            ToastModel.generic(generation: 1),
            configuration: configuration,
            duration: .infinity,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 900)
        ))

        XCTAssertTrue(stack.contains(id))
        stack.hideAll()
    }

    func testCoordinatorAdmitsSixEntriesAcrossFeaturePolicies() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 1_200)
        let generalID = try XCTUnwrap(coordinator.presentGeneral(
            ToastModel.generic(generation: 1),
            duration: 10,
            visibleFrame: visibleFrame
        ))
        let microphoneID = try XCTUnwrap(coordinator.presentMicrophone(
            ToastModel.generic(generation: 2),
            duration: 10,
            visibleFrame: visibleFrame
        ))
        var twitchIDs: [ToastStackController.ID] = []
        for generation in 3...6 {
            twitchIDs.append(try XCTUnwrap(coordinator.presentTwitch(
                ToastModel.generic(generation: UInt64(generation)),
                duration: 10,
                visibleFrame: visibleFrame
            )))
        }

        XCTAssertTrue(stack.contains(generalID))
        XCTAssertTrue(stack.contains(microphoneID))
        XCTAssertTrue(twitchIDs.allSatisfy { stack.contains($0) })
        coordinator.hideAll()
    }

    func testCoordinatorOrdersMicrophoneGeneralThenTwitch() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 1_200)
        let twitchID = try XCTUnwrap(coordinator.presentTwitch(
            ToastModel.generic(generation: 1),
            duration: 10,
            visibleFrame: visibleFrame
        ))
        let generalID = try XCTUnwrap(coordinator.presentGeneral(
            ToastModel.generic(generation: 2),
            duration: 10,
            visibleFrame: visibleFrame
        ))
        let microphoneID = try XCTUnwrap(coordinator.presentMicrophone(
            ToastModel.generic(generation: 3),
            duration: 10,
            visibleFrame: visibleFrame
        ))

        let microphoneFrame = try XCTUnwrap(stack.presentedFrame(for: microphoneID))
        let generalFrame = try XCTUnwrap(stack.presentedFrame(for: generalID))
        let twitchFrame = try XCTUnwrap(stack.presentedFrame(for: twitchID))
        XCTAssertLessThan(microphoneFrame.minY, generalFrame.minY)
        XCTAssertLessThan(generalFrame.minY, twitchFrame.minY)
        coordinator.hideAll()
    }

    func testTemporaryVolumeToastUsesIndependentStackEntry() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 900)
        let generalID = try XCTUnwrap(coordinator.presentGeneral(
            ToastModel.generic(generation: 1),
            duration: .infinity,
            visibleFrame: visibleFrame
        ))
        let volumeID = try XCTUnwrap(coordinator.presentTemporaryVolume(
            ToastModel.generic(generation: 2),
            duration: .infinity,
            visibleFrame: visibleFrame
        ))

        XCTAssertNotEqual(generalID, volumeID)
        XCTAssertTrue(stack.contains(generalID))
        XCTAssertTrue(stack.contains(volumeID))

        let replacementID = try XCTUnwrap(coordinator.presentTemporaryVolume(
            ToastModel.generic(generation: 3),
            duration: .infinity,
            visibleFrame: visibleFrame
        ))
        XCTAssertEqual(replacementID, volumeID)
        XCTAssertTrue(stack.contains(generalID))
        coordinator.hideAll()
    }

    func testDismissingTwitchEntryIsReused() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_200, height: 900)
        let dismissingID = try XCTUnwrap(coordinator.presentTwitch(
            ToastModel.generic(generation: 1),
            duration: .infinity,
            visibleFrame: visibleFrame
        ))
        stack.dismiss(dismissingID)
        XCTAssertTrue(stack.isDismissing(dismissingID))

        let replacementID = try XCTUnwrap(coordinator.presentTwitch(
            ToastModel.generic(generation: 2),
            duration: .infinity,
            visibleFrame: visibleFrame
        ))
        XCTAssertEqual(replacementID, dismissingID)
        XCTAssertFalse(stack.isDismissing(replacementID))
        coordinator.hideAll()
    }

    private func summaryLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 15.75, weight: .semibold)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.cell?.usesSingleLineMode = false
        label.cell?.truncatesLastVisibleLine = true
        return label
    }
}
