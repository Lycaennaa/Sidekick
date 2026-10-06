import AppKit
import CoreAudio
import XCTest

@MainActor
final class MicrophoneToastControllerTests: XCTestCase {
    func testActivityTransitionsPreserveUnknownStateAndHideAfterSustainedInactivity() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        var uptime: TimeInterval = 100
        var snapshot = MicrophoneActivitySnapshot.active(
            .init(id: AudioDeviceID(42), name: "Studio Mic")
        )
        let controller = MicrophoneToastController(
            toastPresentationCoordinator: coordinator,
            settings: makeSettings(),
            uptime: { uptime },
            activitySnapshot: { snapshot }
        )
        controller.start()
        defer { controller.stop() }

        XCTAssertTrue(coordinator.isMicrophonePresented)
        let contentView = try XCTUnwrap(
            NSApp.windows.reversed()
                .compactMap { ($0 as? ToastPanel)?.contentView as? ToastContentView }
                .first
        )
        XCTAssertTrue(
            contentView.subviews
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "Microphone: \"Studio Mic\" active" }
        )

        snapshot = .inactive
        controller.refresh()
        XCTAssertTrue(coordinator.isMicrophonePresented)

        snapshot = .unavailable
        controller.refresh()
        XCTAssertTrue(coordinator.isMicrophonePresented)

        uptime += 1.5
        snapshot = .inactive
        controller.refresh()
        XCTAssertTrue(coordinator.isMicrophonePresented)

        uptime += 0.5
        controller.refresh()
        XCTAssertTrue(coordinator.isMicrophonePresented)

        uptime += 1.5
        controller.refresh()
        XCTAssertFalse(coordinator.isMicrophonePresented)
    }

    func testApplicationIdentityChangesDoNotClearActivitySuppression() {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        var snapshot = MicrophoneActivitySnapshot.active(
            .init(id: AudioDeviceID(42), name: "Studio Mic")
        )
        let controller = MicrophoneToastController(
            toastPresentationCoordinator: coordinator,
            settings: makeSettings(),
            activitySnapshot: { snapshot }
        )
        controller.start()
        defer { controller.stop() }

        controller.hideMicrophoneToastUntilNextActivityChange()
        snapshot = .active(.init(
            id: AudioDeviceID(42),
            name: "Studio Mic",
            applicationNames: ["Zoom"]
        ))
        controller.refresh()
        XCTAssertFalse(coordinator.isMicrophonePresented)

        snapshot = .active(.init(
            id: AudioDeviceID(43),
            name: "Studio Mic",
            applicationNames: ["Zoom"]
        ))
        controller.refresh()
        XCTAssertTrue(coordinator.isMicrophonePresented)
    }

    func testToastIncludesActiveApplication() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        let controller = MicrophoneToastController(
            toastPresentationCoordinator: coordinator,
            settings: makeSettings(),
            activitySnapshot: {
                .active(.init(
                    id: AudioDeviceID(42),
                    name: "Studio Mic",
                    applicationNames: ["Zoom"]
                ))
            }
        )
        controller.start()
        defer { controller.stop() }

        let contentView = try XCTUnwrap(
            NSApp.windows.reversed()
                .compactMap { ($0 as? ToastPanel)?.contentView as? ToastContentView }
                .first
        )
        let expectedSummary = "Microphone: \"Studio Mic\" active in:\nZoom"
        let summaryLabel = try XCTUnwrap(
            contentView.subviews
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == expectedSummary }
        )

        XCTAssertEqual(summaryLabel.stringValue, expectedSummary)
    }

    func testToastIncludesInputGainFooter() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        let controller = MicrophoneToastController(
            toastPresentationCoordinator: coordinator,
            settings: makeSettings(),
            activitySnapshot: {
                .active(.init(
                    id: AudioDeviceID(42),
                    name: "Studio Mic",
                    inputGain: 0.75
                ))
            }
        )
        controller.start()
        defer { controller.stop() }

        let contentView = try XCTUnwrap(
            NSApp.windows.reversed()
                .compactMap { ($0 as? ToastPanel)?.contentView as? ToastContentView }
                .first
        )
        XCTAssertTrue(
            contentView.subviews
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "Input gain: 75%" }
        )
    }

    func testToastIncludesEachActiveApplicationOnItsOwnLine() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        let controller = MicrophoneToastController(
            toastPresentationCoordinator: coordinator,
            settings: makeSettings(),
            activitySnapshot: {
                .active(.init(
                    id: AudioDeviceID(42),
                    name: "Studio Mic",
                    applicationNames: ["Slack", "Zoom"]
                ))
            }
        )
        controller.start()
        defer { controller.stop() }

        let contentView = try XCTUnwrap(
            NSApp.windows.reversed()
                .compactMap { ($0 as? ToastPanel)?.contentView as? ToastContentView }
                .first
        )
        let expectedSummary = "Microphone: \"Studio Mic\" active in:\nSlack\nZoom"
        let summaryLabel = try XCTUnwrap(
            contentView.subviews
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == expectedSummary }
        )

        XCTAssertEqual(summaryLabel.stringValue, expectedSummary)
    }

    func testToastSummarizesAdditionalApplications() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        let applicationNames = (1...9).map { "App \($0)" }
        let controller = MicrophoneToastController(
            toastPresentationCoordinator: coordinator,
            settings: makeSettings(),
            activitySnapshot: {
                .active(.init(
                    id: AudioDeviceID(42),
                    name: "Studio Mic",
                    applicationNames: applicationNames
                ))
            }
        )
        controller.start()
        defer { controller.stop() }

        let contentView = try XCTUnwrap(
            NSApp.windows.reversed()
                .compactMap { ($0 as? ToastPanel)?.contentView as? ToastContentView }
                .first
        )
        let expectedSummary = "Microphone: \"Studio Mic\" active in:\n"
            + "App 1\nApp 2\nApp 3\nApp 4\nApp 5\nApp 6\nApp 7\nApp 8\n+1 more"
        XCTAssertTrue(
            contentView.subviews
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == expectedSummary }
        )
    }

    func testDisabledSettingStopsAndRestartsMicrophoneMonitoring() {
        let suiteName = "MicrophoneToastControllerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Unable to create test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)
        settings.microphoneToastEnabled = false
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        let controller = MicrophoneToastController(
            toastPresentationCoordinator: coordinator,
            settings: settings,
            activitySnapshot: {
                .active(.init(id: AudioDeviceID(42), name: "Studio Mic"))
            }
        )
        defer { controller.stop() }

        controller.start()
        XCTAssertFalse(coordinator.isMicrophonePresented)

        settings.microphoneToastEnabled = true
        controller.applySettings()
        XCTAssertTrue(coordinator.isMicrophonePresented)

        settings.microphoneToastEnabled = false
        controller.applySettings()
        XCTAssertFalse(coordinator.isMicrophonePresented)
    }

    func testHideUntilActivityChangeDoesNotReappearForSameActivity() {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        var uptime: TimeInterval = 100
        var snapshot = MicrophoneActivitySnapshot.active(
            .init(id: AudioDeviceID(42), name: "Studio Mic")
        )
        let controller = MicrophoneToastController(
            toastPresentationCoordinator: coordinator,
            settings: makeSettings(),
            uptime: { uptime },
            activitySnapshot: { snapshot }
        )
        controller.start()
        defer { controller.stop() }

        controller.hideMicrophoneToastUntilNextActivityChange()
        XCTAssertFalse(coordinator.isMicrophonePresented)

        controller.refresh()
        XCTAssertFalse(coordinator.isMicrophonePresented)

        snapshot = .inactive
        controller.refresh()
        uptime += 2
        controller.refresh()
        snapshot = .active(.init(id: AudioDeviceID(42), name: "Studio Mic"))
        controller.refresh()
        XCTAssertTrue(coordinator.isMicrophonePresented)
    }

    func testTimedHideExpiresAndPresentsCurrentActivity() {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        var now = Date(timeIntervalSinceReferenceDate: 100)
        let controller = MicrophoneToastController(
            toastPresentationCoordinator: coordinator,
            settings: makeSettings(),
            now: { now },
            activitySnapshot: {
                .active(.init(id: AudioDeviceID(42), name: "Studio Mic"))
            }
        )
        controller.start()
        defer { controller.stop() }

        controller.hideMicrophoneToast(for: 60)
        now = now.addingTimeInterval(59)
        controller.refresh()
        XCTAssertFalse(coordinator.isMicrophonePresented)

        now = now.addingTimeInterval(1)
        controller.refresh()
        XCTAssertTrue(coordinator.isMicrophonePresented)
    }

    func testPressingToastHidesUntilActivityChanges() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        var uptime: TimeInterval = 100
        var snapshot = MicrophoneActivitySnapshot.active(
            .init(id: AudioDeviceID(42), name: "Studio Mic")
        )
        let controller = MicrophoneToastController(
            toastPresentationCoordinator: coordinator,
            settings: makeSettings(),
            uptime: { uptime },
            activitySnapshot: { snapshot }
        )
        controller.start()
        defer { controller.stop() }

        let contentView = try XCTUnwrap(
            NSApp.windows.reversed()
                .compactMap { ($0 as? ToastPanel)?.contentView as? ToastContentView }
                .first
        )
        XCTAssertTrue(contentView.accessibilityPerformPress())
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        XCTAssertFalse(coordinator.isMicrophonePresented)
        controller.refresh()
        XCTAssertFalse(coordinator.isMicrophonePresented)

        snapshot = .inactive
        controller.refresh()
        uptime += 2
        controller.refresh()
        snapshot = .active(.init(id: AudioDeviceID(42), name: "Studio Mic"))
        controller.refresh()
        XCTAssertTrue(coordinator.isMicrophonePresented)
    }

    func testChangedActiveDeviceRemainsPresented() {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        var snapshot = MicrophoneActivitySnapshot.active(
            .init(id: AudioDeviceID(1), name: "Built-in Mic")
        )
        let controller = MicrophoneToastController(
            toastPresentationCoordinator: coordinator,
            settings: makeSettings(),
            activitySnapshot: { snapshot }
        )
        controller.start()
        defer { controller.stop() }

        snapshot = .active(.init(id: AudioDeviceID(2), name: "USB Mic"))
        controller.refresh()

        XCTAssertTrue(coordinator.isMicrophonePresented)
    }

    func testShowNowRestoresToastDuringDismissal() throws {
        let stack = ToastStackController()
        let coordinator = ToastPresentationCoordinator(stack: stack)
        let controller = MicrophoneToastController(
            toastPresentationCoordinator: coordinator,
            settings: makeSettings(),
            activitySnapshot: {
                .active(.init(id: AudioDeviceID(42), name: "Studio Mic"))
            }
        )
        controller.start()
        defer { controller.stop() }

        let contentView = try XCTUnwrap(
            NSApp.windows.reversed()
                .compactMap { ($0 as? ToastPanel)?.contentView as? ToastContentView }
                .first
        )
        XCTAssertTrue(contentView.accessibilityPerformPress())
        controller.showMicrophoneToast()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        XCTAssertTrue(coordinator.isMicrophonePresented)
    }

    private func makeSettings() -> AppSettings {
        let suiteName = "MicrophoneToastControllerTests"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Unable to create test defaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return AppSettings(defaults: defaults)
    }
}
extension MicrophoneToastControllerTests {
    func testMicrophoneToastMenuRoutesThreeHourHideAndShow() throws {
        var hiddenInterval: TimeInterval?
        var hideCallCount = 0
        var showCallCount = 0
        let menuController = MicrophoneToastMenu(
            onHide: { interval in
                hiddenInterval = interval
                hideCallCount += 1
            },
            onShow: {
                showCallCount += 1
            }
        )

        let hideItem = try XCTUnwrap(
            menuController.menu.items.first { $0.title == "Hide for 3 Hours" }
        )
        let hideAction = try XCTUnwrap(hideItem.action)
        XCTAssertTrue(NSApp.sendAction(hideAction, to: hideItem.target, from: hideItem))
        XCTAssertEqual(hiddenInterval, 3 * 60 * 60)
        XCTAssertEqual(hideCallCount, 1)

        let showItem = try XCTUnwrap(
            menuController.menu.items.first { $0.title == "Show Now" }
        )
        let showAction = try XCTUnwrap(showItem.action)
        XCTAssertTrue(NSApp.sendAction(showAction, to: showItem.target, from: showItem))
        XCTAssertEqual(showCallCount, 1)
    }
}
