import XCTest

final class ClipboardToastStateTests: XCTestCase {
    func testSeedSuppressesExistingClipboardAndChangesEmitOnce() {
        var state = ClipboardToastState(enabled: true)

        state.seed(changeCount: 10)

        XCTAssertNil(state.observe(changeCount: 10))
        XCTAssertNil(state.observe(changeCount: 11))
        XCTAssertNotNil(state.observe(changeCount: 11))
        XCTAssertNil(state.observe(changeCount: 11))
    }

    func testMultipleUnseenChangesResolveCurrentCountOnly() {
        var state = ClipboardToastState(enabled: true)
        state.seed(changeCount: 1)

        XCTAssertNil(state.observe(changeCount: 4))
        XCTAssertNotNil(state.observe(changeCount: 4))
        XCTAssertNil(state.observe(changeCount: 4))
    }

    func testLatestChangeInBurstEmitsAfterStablePoll() {
        var state = ClipboardToastState(enabled: true)
        state.seed(changeCount: 10)

        XCTAssertNil(state.observe(changeCount: 11))
        XCTAssertNil(state.observe(changeCount: 12))
        XCTAssertNotNil(state.observe(changeCount: 12))
        XCTAssertNil(state.observe(changeCount: 12))
    }

    func testDisableClearsPauseAndEnableRequiresReseed() {
        var state = ClipboardToastState(enabled: true)
        state.seed(changeCount: 1)
        XCTAssertTrue(state.beginPause(until: nil))

        XCTAssertTrue(state.setEnabled(false))
        XCTAssertEqual(state.status, .disabled)
        XCTAssertNil(state.pause)
        XCTAssertTrue(state.setEnabled(true))
        XCTAssertNil(state.observe(changeCount: 2))
    }

    func testTimedAndIndefinitePauseTransitions() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        var state = ClipboardToastState(enabled: true)

        XCTAssertTrue(state.beginPause(until: now.addingTimeInterval(60)))
        XCTAssertEqual(state.status, .paused)
        XCTAssertFalse(state.expirePause(at: now.addingTimeInterval(59)))
        XCTAssertTrue(state.expirePause(at: now.addingTimeInterval(60)))
        XCTAssertEqual(state.status, .active)

        XCTAssertTrue(state.beginPause(until: nil))
        XCTAssertFalse(state.expirePause(at: now.addingTimeInterval(10_000)))
        XCTAssertTrue(state.resume())
        XCTAssertEqual(state.status, .active)
    }

    func testNestedSuspensionsResumeOnlyAfterBothClear() {
        var state = ClipboardToastState(enabled: true)

        XCTAssertTrue(state.addSuspension(.sessionInactive))
        XCTAssertTrue(state.addSuspension(.systemSleeping))
        XCTAssertEqual(state.status, .suspended)
        XCTAssertTrue(state.removeSuspension(.systemSleeping))
        XCTAssertEqual(state.status, .suspended)
        XCTAssertTrue(state.removeSuspension(.sessionInactive))
        XCTAssertEqual(state.status, .active)
    }

    func testTerminationRejectsLaterChanges() {
        var state = ClipboardToastState(enabled: true)
        state.seed(changeCount: 1)
        state.terminate()

        XCTAssertEqual(state.status, .terminating)
        XCTAssertNil(state.observe(changeCount: 2))
        XCTAssertFalse(state.setEnabled(false))
        XCTAssertFalse(state.beginPause(until: nil))
        XCTAssertFalse(state.addSuspension(.systemSleeping))
    }
    func testObservationStateKeepsLatestAttributionAcrossTransientWrites() {
        let baseline = ClipboardTextFingerprint(
            typeIdentifier: "public.utf8-plain-text",
            itemTypeIdentifiers: ["public.utf8-plain-text"],
            byteCount: 4,
            digest: Data([1, 2, 3, 4])
        )
        let firstSource = ClipboardSourceApplication(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let latestSource = ClipboardSourceApplication(name: "Finder", bundleIdentifier: "com.apple.finder")
        var observation = ClipboardToastObservationState()
        observation.reseed(sourceApplication: firstSource, fingerprint: baseline)

        observation.recordChange(
            sourceApplication: firstSource,
            sourceBundleIdentifierForExclusion: firstSource.bundleIdentifier,
            previousChangeCount: 10,
            currentChangeCount: 11,
            containsTransientMarker: true
        )
        observation.recordChange(
            sourceApplication: latestSource,
            sourceBundleIdentifierForExclusion: latestSource.bundleIdentifier,
            previousChangeCount: 11,
            currentChangeCount: 12,
            containsTransientMarker: false
        )

        XCTAssertEqual(
            observation.consumeAttribution(),
            .init(
                sourceApplication: latestSource,
                sourceBundleIdentifierForExclusion: latestSource.bundleIdentifier
            )
        )
        XCTAssertTrue(observation.shouldSuppressTransientRestore(current: baseline))
        observation.resolveTransientRestore()
        XCTAssertFalse(observation.shouldSuppressTransientRestore(current: baseline))
    }

    func testObservationStateRejectsSourceAfterApplicationSwitch() {
        let safari = ClipboardSourceApplication(name: "Safari", bundleIdentifier: "com.apple.Safari")
        let finder = ClipboardSourceApplication(name: "Finder", bundleIdentifier: "com.apple.finder")
        var observation = ClipboardToastObservationState()
        observation.reseed(sourceApplication: safari, fingerprint: nil)
        observation.markSourceApplicationChanged()

        XCTAssertNil(
            observation.sourceApplicationForChange(
                current: finder,
                changedDuringSample: false
            )
        )
    }

    func testObservationStateCompletesStableFingerprintAtomically() {
        let fingerprint = ClipboardTextFingerprint(
            typeIdentifier: "public.utf8-plain-text",
            itemTypeIdentifiers: ["public.utf8-plain-text"],
            byteCount: 1,
            digest: Data([9])
        )
        var observation = ClipboardToastObservationState()

        observation.completeStableObservation(fingerprint: fingerprint)

        XCTAssertEqual(observation.lastStableTextFingerprint, fingerprint)
        XCTAssertFalse(observation.shouldSuppressTransientRestore(current: fingerprint))
    }

}
