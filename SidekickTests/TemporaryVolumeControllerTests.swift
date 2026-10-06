import CoreAudio
import Foundation
import XCTest

@MainActor
final class TemporaryVolumeControllerTests: XCTestCase {
    func testMuteRestoresVolumeWithFadeAfterTimerExpires() async {
        let sleeper = ManualVolumeSleeper()
        let volume = TestVolumeBox(value: 0.8)
        let controller = makeController(volume: volume, sleeper: sleeper)
        let restored = expectation(description: "volume restored")
        controller.onEvent = { event in
            if case .restored = event { restored.fulfill() }
        }

        XCTAssertTrue(controller.mute(deviceID: testDeviceID, for: 1))
        XCTAssertEqual(volume.value, 0.8, accuracy: 0.001)
        XCTAssertTrue(volume.muted)
        XCTAssertTrue(volume.writes.isEmpty)
        await finishTimerAndFade(sleeper)
        await fulfillment(of: [restored], timeout: 1)

        XCTAssertEqual(volume.value, 0.8, accuracy: 0.01)
        XCTAssertFalse(volume.muted)
        XCTAssertFalse(controller.hasActiveTimer(for: testDeviceID))
        XCTAssertGreaterThan(volume.writes.count, 1)
        XCTAssertEqual(volume.muteWrites, [true, false])
    }

    func testExpiryFadesToManualVolumeChange() async {
        let sleeper = ManualVolumeSleeper()
        let volume = TestVolumeBox(value: 0.8)
        let controller = makeController(volume: volume, sleeper: sleeper)
        let finished = expectation(description: "timer finished")
        controller.onEvent = { event in
            if case .restored = event { finished.fulfill() }
        }

        XCTAssertTrue(controller.mute(deviceID: testDeviceID, for: 1))
        await sleeper.waitUntilRequestCount(1)
        volume.value = 0.35
        sleeper.autoResume = true
        sleeper.resume()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(volume.value, 0.35, accuracy: 0.01)
        XCTAssertFalse(volume.muted)
        XCTAssertFalse(controller.hasActiveTimer(for: testDeviceID))
    }

    func testExpiryPreservesManualUnmute() async {
        let sleeper = ManualVolumeSleeper()
        let volume = TestVolumeBox(value: 0.8)
        let controller = makeController(volume: volume, sleeper: sleeper)
        let finished = expectation(description: "timer finished")
        controller.onEvent = { event in
            if case .restored = event { finished.fulfill() }
        }

        XCTAssertTrue(controller.mute(deviceID: testDeviceID, for: 1))
        await sleeper.waitUntilRequestCount(1)
        volume.muted = false
        sleeper.resume()
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(volume.value, 0.8, accuracy: 0.001)
        XCTAssertFalse(volume.muted)
        XCTAssertTrue(volume.writes.isEmpty)
    }

    func testCancelRestoresWithFadeAndCanceledTimerCannotWriteAgain() async {
        let sleeper = ManualVolumeSleeper()
        let volume = TestVolumeBox(value: 0.8)
        let controller = makeController(volume: volume, sleeper: sleeper)
        let restored = expectation(description: "volume restored")
        controller.onEvent = { event in
            if case .restored = event { restored.fulfill() }
        }

        XCTAssertTrue(controller.mute(deviceID: testDeviceID, for: 1))
        await sleeper.waitUntilRequestCount(1)
        controller.restoreNow(deviceID: testDeviceID)

        sleeper.autoResume = true
        sleeper.resume()
        await fulfillment(of: [restored], timeout: 1)

        XCTAssertEqual(volume.value, 0.8, accuracy: 0.01)
        XCTAssertFalse(volume.muted)
        XCTAssertFalse(controller.hasActiveTimer(for: testDeviceID))
        XCTAssertGreaterThan(volume.writes.count, 1)
        XCTAssertEqual(volume.muteWrites, [true, false])
    }

    func testNewTimerOwnsMuteAfterOlderTimerIsCanceled() async {
        let sleeper = ManualVolumeSleeper()
        let volume = TestVolumeBox(value: 0.8)
        let controller = makeController(volume: volume, sleeper: sleeper)
        let restored = expectation(description: "new timer restored volume")
        controller.onEvent = { event in
            if case .restored = event { restored.fulfill() }
        }

        XCTAssertTrue(controller.mute(deviceID: testDeviceID, for: 1))
        await sleeper.waitUntilRequestCount(1)
        XCTAssertTrue(controller.mute(deviceID: testDeviceID, for: 1))

        sleeper.resume()
        await sleeper.waitUntilRequestCount(2)
        XCTAssertTrue(volume.muted)
        XCTAssertTrue(volume.writes.isEmpty)

        sleeper.autoResume = true
        sleeper.resume()
        await fulfillment(of: [restored], timeout: 1)

        XCTAssertEqual(volume.value, 0.8, accuracy: 0.01)
        XCTAssertFalse(volume.muted)
        XCTAssertFalse(controller.hasActiveTimer(for: testDeviceID))
    }

    func testDelayedMuteStartsLaterAndUsesMuteDuration() async {
        let sleeper = ManualVolumeSleeper()
        let volume = TestVolumeBox(value: 0.8)
        let controller = makeController(volume: volume, sleeper: sleeper)
        var events: [TemporaryVolumeEvent] = []
        let restored = expectation(description: "delayed mute restored")
        controller.onEvent = { event in
            events.append(event)
            if case .restored = event {
                restored.fulfill()
            }
        }

        XCTAssertTrue(controller.scheduleMute(deviceID: testDeviceID, startDelay: 1, duration: 2))
        XCTAssertTrue(controller.hasPendingTimer(for: testDeviceID))
        XCTAssertFalse(volume.muted)

        await sleeper.waitUntilRequestCount(1)
        sleeper.resume()
        await sleeper.waitUntilRequestCount(2)
        XCTAssertFalse(controller.hasPendingTimer(for: testDeviceID))
        XCTAssertTrue(volume.muted)
        sleeper.autoResume = true
        sleeper.resume()
        await fulfillment(of: [restored], timeout: 1)

        XCTAssertFalse(controller.hasActiveTimer(for: testDeviceID))
        XCTAssertFalse(volume.muted)
        XCTAssertTrue(events.contains {
            if case .scheduled(testDeviceID, 1, 2) = $0 { return true }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .muted(testDeviceID, 2) = $0 { return true }
            return false
        })
        XCTAssertTrue(events.contains {
            if case .restored(testDeviceID) = $0 { return true }
            return false
        })
    }

    func testCancellingDelayedMuteStopsPendingOperation() async {
        let sleeper = ManualVolumeSleeper()
        let volume = TestVolumeBox(value: 0.8)
        let controller = makeController(volume: volume, sleeper: sleeper)
        var events: [TemporaryVolumeEvent] = []
        controller.onEvent = { events.append($0) }

        XCTAssertTrue(controller.scheduleMute(deviceID: testDeviceID, startDelay: 1, duration: 2))
        await sleeper.waitUntilRequestCount(1)
        controller.restoreNow(deviceID: testDeviceID)
        XCTAssertFalse(controller.hasActiveTimer(for: testDeviceID))
        XCTAssertFalse(volume.muted)
        XCTAssertTrue(events.contains {
            if case .cancelled(testDeviceID) = $0 { return true }
            return false
        })

        sleeper.resume()
        await sleeper.waitUntilExit()
        XCTAssertFalse(volume.muted)
        XCTAssertTrue(volume.writes.isEmpty)
    }

    func testScheduleMuteRejectsReplacementWhileMuted() async {
        let sleeper = ManualVolumeSleeper()
        let volume = TestVolumeBox(value: 0.8)
        let controller = makeController(volume: volume, sleeper: sleeper)
        var failure: TemporaryVolumeError?
        controller.onFailure = { failure = $0 }

        XCTAssertTrue(controller.mute(deviceID: testDeviceID, for: 1))
        await sleeper.waitUntilRequestCount(1)
        XCTAssertFalse(controller.scheduleMute(deviceID: testDeviceID, startDelay: 1, duration: 2))
        XCTAssertEqual(failure, .operationAlreadyActive)

        controller.restoreNow(deviceID: testDeviceID)
        sleeper.autoResume = true
        sleeper.resume()
    }

    func testStopRetainsOperationWhenBothRestoreWritesFail() async {
        let sleeper = ManualVolumeSleeper()
        let volume = TestVolumeBox(value: 0.8)
        let controller = makeController(volume: volume, sleeper: sleeper)
        var failures: [TemporaryVolumeError] = []
        controller.onFailure = { failures.append($0) }

        XCTAssertTrue(controller.mute(deviceID: testDeviceID, for: 1))
        await sleeper.waitUntilRequestCount(1)
        volume.writeVolumeError = .writeFailed(-10)
        volume.writeMuteError = .writeFailed(-11)
        controller.stop()

        XCTAssertTrue(controller.hasActiveTimer(for: testDeviceID))
        XCTAssertEqual(failures.count, 2)

        volume.writeVolumeError = nil
        volume.writeMuteError = nil
        let restored = expectation(description: "retry restored")
        controller.onEvent = { event in
            if case .restored = event { restored.fulfill() }
        }
        sleeper.autoResume = true
        controller.restoreNow(deviceID: testDeviceID)
        sleeper.resume()
        await fulfillment(of: [restored], timeout: 1)
        XCTAssertFalse(controller.hasActiveTimer(for: testDeviceID))
    }

    func testMuteReadAndWriteFailuresAreReported() {
        let sleeper = ManualVolumeSleeper()
        let volume = TestVolumeBox(value: 0.8)
        let controller = makeController(volume: volume, sleeper: sleeper)
        var failures: [TemporaryVolumeError] = []
        controller.onFailure = { failures.append($0) }

        volume.readVolumeError = .readFailed(-20)
        XCTAssertFalse(controller.mute(deviceID: testDeviceID, for: 1))
        volume.readVolumeError = nil
        volume.writeMuteErrorWhenMuted = .writeFailed(-21)
        XCTAssertFalse(controller.mute(deviceID: testDeviceID, for: 1))

        XCTAssertEqual(failures, [
            .coreAudio(.readFailed(-20)),
            .coreAudio(.writeFailed(-21))
        ])
        XCTAssertFalse(controller.hasActiveTimer(for: testDeviceID))
    }

    func testExpiryReadFailureRetainsOperationForExplicitRetry() async {
        let sleeper = ManualVolumeSleeper()
        let volume = TestVolumeBox(value: 0.8)
        let controller = makeController(volume: volume, sleeper: sleeper)
        let failed = expectation(description: "expiry read failure reported")
        let restored = expectation(description: "retry restored volume")
        controller.onFailure = { _ in failed.fulfill() }
        controller.onEvent = { event in
            if case .restored = event { restored.fulfill() }
        }

        XCTAssertTrue(controller.mute(deviceID: testDeviceID, for: 1))
        await sleeper.waitUntilRequestCount(1)
        volume.readVolumeError = .readFailed(-22)
        sleeper.autoResume = true
        sleeper.resume()
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertTrue(controller.hasActiveTimer(for: testDeviceID))

        volume.readVolumeError = nil
        controller.restoreNow(deviceID: testDeviceID)
        await fulfillment(of: [restored], timeout: 1)
        XCTAssertFalse(controller.hasActiveTimer(for: testDeviceID))
    }

    func testUnmuteAndRollbackFailuresRemainRetryable() async {
        let sleeper = ManualVolumeSleeper()
        let volume = TestVolumeBox(value: 0.8)
        let controller = makeController(volume: volume, sleeper: sleeper)
        var failures: [TemporaryVolumeError] = []
        let twoFailures = expectation(description: "mute and rollback failures reported")
        let restored = expectation(description: "retry restored volume")
        controller.onFailure = { error in
            failures.append(error)
            if failures.count == 2 { twoFailures.fulfill() }
        }
        controller.onEvent = { event in
            if case .restored = event { restored.fulfill() }
        }

        XCTAssertTrue(controller.mute(deviceID: testDeviceID, for: 1))
        await sleeper.waitUntilRequestCount(1)
        volume.writeMuteErrorWhenUnmuted = .writeFailed(-23)
        volume.writeVolumeErrorForNonZero = .writeFailed(-24)
        sleeper.autoResume = true
        sleeper.resume()
        await fulfillment(of: [twoFailures], timeout: 1)

        XCTAssertTrue(controller.hasActiveTimer(for: testDeviceID))
        XCTAssertTrue(volume.muted)
        XCTAssertEqual(volume.value, 0, accuracy: 0.001)
        XCTAssertTrue(failures.contains(.coreAudio(.writeFailed(-23))))
        XCTAssertTrue(failures.contains(.coreAudio(.writeFailed(-24))))

        volume.writeMuteErrorWhenUnmuted = nil
        volume.writeVolumeErrorForNonZero = nil
        controller.restoreNow(deviceID: testDeviceID)
        await fulfillment(of: [restored], timeout: 1)
        XCTAssertFalse(controller.hasActiveTimer(for: testDeviceID))
    }

    func testFadeWriteFailureRemainsRetryable() async {
        let sleeper = ManualVolumeSleeper()
        let volume = TestVolumeBox(value: 0.8)
        let controller = makeController(volume: volume, sleeper: sleeper)
        let failed = expectation(description: "fade failure reported")
        let restored = expectation(description: "retry restored volume")
        controller.onFailure = { _ in failed.fulfill() }
        controller.onEvent = { event in
            if case .restored = event { restored.fulfill() }
        }

        XCTAssertTrue(controller.mute(deviceID: testDeviceID, for: 1))
        await sleeper.waitUntilRequestCount(1)
        volume.writeVolumeErrorForNonZero = .writeFailed(-25)
        sleeper.autoResume = true
        sleeper.resume()
        await fulfillment(of: [failed], timeout: 1)

        XCTAssertTrue(controller.hasActiveTimer(for: testDeviceID))
        XCTAssertFalse(volume.muted)
        XCTAssertEqual(volume.value, 0, accuracy: 0.001)

        volume.writeVolumeErrorForNonZero = nil
        controller.restoreNow(deviceID: testDeviceID)
        await fulfillment(of: [restored], timeout: 1)
        XCTAssertFalse(controller.hasActiveTimer(for: testDeviceID))
    }

    private let testDeviceID = AudioDeviceID(42)

    private func makeController(
        volume: TestVolumeBox,
        sleeper: ManualVolumeSleeper
    ) -> TemporaryVolumeController {
        let device = AudioOutputDevice(
            id: testDeviceID,
            name: "Test Output",
            isDefault: true,
            supportsTemporaryMute: true
        )
        let dependencies = TemporaryVolumeDependencies(
            devices: { [device] in [device] },
            readVolume: { [volume] _ in
                if let error = volume.readVolumeError { throw error }
                return volume.value
            },
            setVolume: { [volume] value, _ in
                if let error = volume.writeVolumeError { throw error }
                if value == 0, let error = volume.writeVolumeErrorForZero { throw error }
                if value > 0, let error = volume.writeVolumeErrorForNonZero { throw error }
                volume.value = value
                volume.writes.append(value)
            },
            readMuted: { [volume] _ in
                if let error = volume.readMuteError { throw error }
                return volume.muted
            },
            setMuted: { [volume] muted, _ in
                if let error = volume.writeMuteError { throw error }
                if muted, let error = volume.writeMuteErrorWhenMuted { throw error }
                if !muted, let error = volume.writeMuteErrorWhenUnmuted { throw error }
                volume.muted = muted
                volume.muteWrites.append(muted)
            },
            sleep: { [sleeper] duration in
                try await sleeper.sleep(duration)
            }
        )
        return TemporaryVolumeController(dependencies: dependencies)
    }

    private func finishTimerAndFade(_ sleeper: ManualVolumeSleeper) async {
        await sleeper.waitUntilRequestCount(1)
        sleeper.autoResume = true
        sleeper.resume()
    }
}

@MainActor
private final class TestVolumeBox {
    var value: Float32
    var muted = false
    var writes: [Float32] = []
    var muteWrites: [Bool] = []
    var readVolumeError: CoreAudioOutputVolumeError?
    var writeVolumeError: CoreAudioOutputVolumeError?
    var writeVolumeErrorForZero: CoreAudioOutputVolumeError?
    var writeVolumeErrorForNonZero: CoreAudioOutputVolumeError?
    var readMuteError: CoreAudioOutputVolumeError?
    var writeMuteError: CoreAudioOutputVolumeError?
    var writeMuteErrorWhenMuted: CoreAudioOutputVolumeError?
    var writeMuteErrorWhenUnmuted: CoreAudioOutputVolumeError?
    init(value: Float32) {
        self.value = value
    }
}

@MainActor
private final class ManualVolumeSleeper {
    private var continuation: CheckedContinuation<Void, Error>?
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []
    private var requestWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var isWaiting = false
    private var didExit = false

    private(set) var requestCount = 0
    var autoResume = false

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        requestCount += 1
        signalRequestWaiters()
        guard !autoResume else { return }

        isWaiting = true
        didExit = false
        for waiter in readyWaiters {
            waiter.resume()
        }
        readyWaiters.removeAll()

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
        isWaiting = false
        didExit = true
        for waiter in exitWaiters {
            waiter.resume()
        }
        exitWaiters.removeAll()
        try Task.checkCancellation()
    }

    func resume() {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }

    func waitUntilWaiting() async {
        guard !isWaiting else { return }
        await withCheckedContinuation { continuation in
            readyWaiters.append(continuation)
        }
    }

    func waitUntilRequestCount(_ count: Int) async {
        guard requestCount < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count: count, continuation: continuation))
        }
    }

    func waitUntilExit() async {
        if !isWaiting, didExit { return }
        await withCheckedContinuation { continuation in
            exitWaiters.append(continuation)
        }
    }

    private func signalRequestWaiters() {
        let ready = requestWaiters.filter { $0.count <= requestCount }
        requestWaiters.removeAll { $0.count <= requestCount }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}
