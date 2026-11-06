@preconcurrency import UserNotifications
import XCTest

@MainActor
final class TwitchNotificationDeliveryTests: XCTestCase {
    func testDeliverySchedulesEachCompletedAvatarWithoutBatchBarrier() async {
        let source = ProfileResultSource()
        let notifications = NotificationRecorder()
        let owner = makeTwitchDeliveryOwner(source: source, notifications: notifications)
        let first = twitchTestStream(id: "first", userID: "user-1")
        let second = twitchTestStream(id: "second", userID: "user-2")
        var delivered: [String] = []
        owner.activate(generation: 7)

        let delivery = Task {
            await owner.deliver(streams: [first, second], session: twitchTestSession(), generation: 7) { event in
                if case let .streamDelivered(stream, _) = event {
                    delivered.append(stream.id)
                }
            }
        }
        await source.waitForSubscriber()

        source.yield(.init(userID: second.userID, data: nil))
        await twitchEventually { notifications.requestIdentifiers == ["twitch-stream-7-second"] }
        XCTAssertEqual(delivered, ["second"])
        XCTAssertFalse(delivery.isCancelled)

        source.yield(.init(userID: first.userID, data: nil))
        source.finish()
        let failedIDs = await delivery.value
        XCTAssertEqual(failedIDs, [])
        XCTAssertEqual(delivered, ["second", "first"])
        XCTAssertTrue(owner.isCleanupMonitorRunning)
    }

    func testDeliveryRequiresExplicitActivationAndCancelStaysInactive() async {
        let source = ProfileResultSource()
        let notifications = NotificationRecorder()
        let owner = makeTwitchDeliveryOwner(source: source, notifications: notifications)
        let stream = twitchTestStream(id: "inactive", userID: "inactive-user")

        let beforeActivation = await owner.deliver(
            streams: [stream],
            session: twitchTestSession(),
            generation: 1
        ) { _ in }
        XCTAssertEqual(beforeActivation, [])
        XCTAssertTrue(notifications.requestIdentifiers.isEmpty)
        XCTAssertFalse(source.hasSubscriber)

        owner.activate(generation: 1)
        owner.cancel()
        let afterCancellation = await owner.deliver(
            streams: [stream],
            session: twitchTestSession(),
            generation: 1
        ) { _ in }
        XCTAssertEqual(afterCancellation, [])
        XCTAssertTrue(notifications.requestIdentifiers.isEmpty)
        XCTAssertFalse(source.hasSubscriber)
    }

    func testPendingReconciliationKeepsIdentifiersAddedDuringQuery() async {
        let notifications = NotificationRecorder()
        let gate = PendingQueryGate()
        let owner = TwitchDeliveryOwner(
            dependencies: .init(
                profileImages: { userIDs, _ in
                    AsyncThrowingStream { continuation in
                        for userID in userIDs {
                            continuation.yield(.init(userID: userID, data: nil))
                        }
                        continuation.finish()
                    }
                },
                notifications: notifications.makeClient(pendingIdentifiers: {
                    await gate.wait()
                }),
                sleeper: .init(sleep: { _ in
                    try await twitchSuspendUntilCancelled()
                }),
                cleanupInterval: 2
            )
        )
        owner.activate(generation: 1)

        let initialDelivery = Task {
            await owner.deliver(
                streams: [twitchTestStream(id: "one", userID: "one")],
                session: twitchTestSession(),
                generation: 1
            ) { _ in }
        }
        _ = await initialDelivery.value
        XCTAssertEqual(owner.pendingIdentifierCount, 1)

        let reconciliation = Task {
            await owner.reconcilePendingNotifications()
        }
        await twitchEventuallyAsync { await gate.hasWaiter }

        let addedDelivery = Task {
            await owner.deliver(
                streams: [twitchTestStream(id: "two", userID: "two")],
                session: twitchTestSession(),
                generation: 1
            ) { _ in }
        }
        _ = await addedDelivery.value
        XCTAssertEqual(owner.pendingIdentifierCount, 2)

        await gate.resume(with: ["twitch-stream-1-one"])
        await reconciliation.value
        XCTAssertEqual(owner.pendingIdentifierCount, 2)
        owner.cancel()
    }

    func testPendingReconciliationKeepsIdentifierWhileAddIsInFlight() async {
        let addStarted = expectation(description: "Notification add started")
        let addGate = AsyncGate()
        let queryGate = AsyncGate()
        let notifications = TwitchNotificationCenterClient(
            authorizationStatus: { .authorized },
            requestAuthorization: { true },
            add: { _ in
                addStarted.fulfill()
                await addGate.wait()
            },
            pendingIdentifiers: {
                await queryGate.wait()
                return []
            },
            removePending: { _ in },
            removeDelivered: { _ in }
        )
        let scheduler = TwitchNotificationScheduler(
            notifications: notifications,
            sleeper: .init(sleep: { _ in
                try await twitchSuspendUntilCancelled()
            })
        )
        scheduler.activate(generation: 1)
        let content = UNMutableNotificationContent()
        let scheduled = Task {
            await scheduler.schedule(
                identifier: "in-flight",
                content: content,
                generation: 1
            )
        }

        await fulfillment(of: [addStarted], timeout: 1)
        let reconciliation = Task {
            await scheduler.reconcilePendingNotifications()
        }
        await twitchEventuallyAsync { await queryGate.hasWaiter }
        await queryGate.open()
        await reconciliation.value
        XCTAssertEqual(scheduler.pendingIdentifierCount, 1)

        await addGate.open()
        let didSchedule = await scheduled.value
        XCTAssertTrue(didSchedule)
        XCTAssertEqual(scheduler.pendingIdentifierCount, 1)
        scheduler.cancel()
    }

    func testDeliveryUsesOneCleanupMonitorAndReconcilesCompleteSet() async {
        let source = ProfileResultSource()
        let notifications = NotificationRecorder()
        let owner = makeTwitchDeliveryOwner(source: source, notifications: notifications)
        owner.activate(generation: 1)
        let streams = [
            twitchTestStream(id: "one", userID: "one"),
            twitchTestStream(id: "two", userID: "two")
        ]
        let delivery = Task {
            await owner.deliver(streams: streams, session: twitchTestSession(), generation: 1) { _ in }
        }
        await source.waitForSubscriber()
        source.yield(.init(userID: "one", data: nil))
        source.yield(.init(userID: "two", data: nil))
        source.finish()
        _ = await delivery.value

        XCTAssertEqual(owner.pendingIdentifierCount, 2)
        XCTAssertTrue(owner.isCleanupMonitorRunning)
        notifications.systemPendingIdentifiers = ["twitch-stream-1-two"]
        await owner.reconcilePendingNotifications()
        XCTAssertEqual(owner.pendingIdentifierCount, 1)
        XCTAssertTrue(owner.isCleanupMonitorRunning)

        owner.cancel()
        XCTAssertEqual(owner.pendingIdentifierCount, 0)
        XCTAssertFalse(owner.isCleanupMonitorRunning)
        XCTAssertEqual(Set(notifications.removedPendingIdentifiers), ["twitch-stream-1-two"])
    }

    func testDeliveryCancellationPreventsLateStreamSideEffects() async {
        let source = ProfileResultSource()
        let notifications = NotificationRecorder()
        let owner = makeTwitchDeliveryOwner(source: source, notifications: notifications)
        var delivered = false
        owner.activate(generation: 3)
        let delivery = Task {
            await owner.deliver(
                streams: [twitchTestStream(id: "late", userID: "late-user")],
                session: twitchTestSession(),
                generation: 3
            ) { event in
                if case .streamDelivered = event { delivered = true }
            }
        }
        await source.waitForSubscriber()

        owner.cancel()
        source.yield(.init(userID: "late-user", data: nil))
        source.finish()
        _ = await delivery.value

        XCTAssertFalse(delivered)
        XCTAssertTrue(notifications.requestIdentifiers.isEmpty)
    }
    func testDeliveryAndTestOwnersShareOneCleanupMonitor() async {
        let source = ProfileResultSource()
        let notifications = NotificationRecorder()
        let sleeper = TwitchCleanupMonitorProbe()
        let testSession = twitchTestSession()
        let scheduler = TwitchNotificationScheduler(
            notifications: notifications.client,
            sleeper: .init(sleep: { interval in
                try await sleeper.sleep(interval)
            }),
            cleanupInterval: 2
        )
        let deliveryOwner = TwitchDeliveryOwner(
            dependencies: .init(
                profileImages: { _, _ in source.makeStream() },
                notifications: notifications.client,
                sleeper: .init(sleep: { _ in
                    try await twitchSuspendUntilCancelled()
                }),
                cleanupInterval: 2
            ),
            scheduler: scheduler
        )
        let testOwner = TwitchTestNotificationOwner(
            dependencies: .init(
                storedTokenState: { .absent },
                authenticate: { _ in testSession },
                profileImage: { _, _ in
                    throw CancellationError()
                },
                notifications: notifications.client
            ),
            scheduler: scheduler
        )
        deliveryOwner.activate(generation: 1)
        let delivery = Task {
            await deliveryOwner.deliver(
                streams: [twitchTestStream(id: "delivery", userID: "delivery-user")],
                session: twitchTestSession(),
                generation: 1
            ) { _ in }
        }
        await source.waitForSubscriber()
        source.yield(.init(userID: "delivery-user", data: nil))
        source.finish()
        _ = await delivery.value
        await sleeper.waitUntilSleeping()

        await sendTestNotification(using: testOwner, notifications: notifications)
        let sleepCount = await sleeper.sleepCount
        XCTAssertEqual(sleepCount, 1)
        XCTAssertTrue(scheduler.isCleanupMonitorRunning)

        deliveryOwner.cancel()
        XCTAssertEqual(notifications.systemPendingIdentifiers, ["twitch-test-notification-1"])
        XCTAssertTrue(scheduler.isCleanupMonitorRunning)
        testOwner.cancel()
        XCTAssertTrue(notifications.systemPendingIdentifiers.isEmpty)
        await sleeper.waitUntilCancelled()
        let wasCancelled = await sleeper.wasCancelled
        XCTAssertTrue(wasCancelled)
    }
    private func sendTestNotification(
        using owner: TwitchTestNotificationOwner,
        notifications: NotificationRecorder
    ) async {
        let completed = expectation(description: "test notification send completed")
        owner.send(username: nil, tokenSaveInProgress: false) { event in
            if case .finished = event {
                completed.fulfill()
            }
        }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertFalse(owner.isSending)
        XCTAssertTrue(notifications.requestIdentifiers.contains("twitch-test-notification-1"))
    }

}

private actor TwitchCleanupMonitorProbe {
    private let sleepGate = AsyncGate()
    private let cancellationGate = AsyncGate()
    private(set) var sleepCount = 0
    private(set) var wasCancelled = false

    func sleep(_: TimeInterval) async throws {
        sleepCount += 1
        do {
            try await withTaskCancellationHandler {
                await sleepGate.wait()
                try Task.checkCancellation()
            } onCancel: {
                Task { await sleepGate.open() }
            }
        } catch {
            wasCancelled = true
            await cancellationGate.open()
            throw error
        }
    }

    func waitUntilSleeping() async {
        await sleepGate.waitUntilWaiterAttached()
    }

    func waitUntilCancelled() async {
        await cancellationGate.wait()
    }
}
