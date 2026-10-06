import Foundation

struct ClipboardSourceApplication: Equatable {
    let name: String?
    let bundleIdentifier: String?
}

struct ClipboardToastObservationState {
    struct Attribution: Equatable {
        let sourceApplication: ClipboardSourceApplication?
        let sourceBundleIdentifierForExclusion: String?
    }

    private enum TransientResolution {
        case none
        case awaitingRestore(baseline: ClipboardTextFingerprint?)
    }

    private var observedSourceApplication: ClipboardSourceApplication?
    private var sourceApplicationChangedSincePoll = false
    private var pendingAttribution: Attribution?
    private var transientResolution = TransientResolution.none
    private(set) var lastStableTextFingerprint: ClipboardTextFingerprint?

    mutating func reseed(
        sourceApplication: ClipboardSourceApplication?,
        fingerprint: ClipboardTextFingerprint?
    ) {
        observedSourceApplication = sourceApplication
        sourceApplicationChangedSincePoll = false
        lastStableTextFingerprint = fingerprint
        pendingAttribution = nil
        transientResolution = .none
    }

    mutating func acknowledge(fingerprint: ClipboardTextFingerprint?) {
        lastStableTextFingerprint = fingerprint
        pendingAttribution = nil
        transientResolution = .none
    }

    mutating func markSourceApplicationChanged() {
        sourceApplicationChangedSincePoll = true
    }

    mutating func sourceApplicationForChange(
        current: ClipboardSourceApplication?,
        changedDuringSample: Bool
    ) -> ClipboardSourceApplication? {
        let attributed = attributedSourceApplication(
            previous: observedSourceApplication,
            current: current,
            applicationChanged: sourceApplicationChangedSincePoll || changedDuringSample
        )
        observedSourceApplication = current
        sourceApplicationChangedSincePoll = false
        return attributed
    }

    mutating func recordChange(
        sourceApplication: ClipboardSourceApplication?,
        sourceBundleIdentifierForExclusion: String?,
        previousChangeCount: Int?,
        currentChangeCount: Int,
        containsTransientMarker: Bool
    ) {
        pendingAttribution = Attribution(
            sourceApplication: sourceApplication,
            sourceBundleIdentifierForExclusion: sourceBundleIdentifierForExclusion
        )
        guard shouldTrackTransientPasteboardChange(
            previousChangeCount: previousChangeCount,
            currentChangeCount: currentChangeCount,
            containsTransientMarker: containsTransientMarker
        ) else {
            return
        }
        if case .none = transientResolution {
            transientResolution = .awaitingRestore(baseline: lastStableTextFingerprint)
        }
    }

    mutating func consumeAttribution() -> Attribution? {
        defer { pendingAttribution = nil }
        return pendingAttribution
    }

    func shouldSuppressTransientRestore(current: ClipboardTextFingerprint?) -> Bool {
        guard case let .awaitingRestore(baseline) = transientResolution else { return false }
        return shouldSuppressTransientTextRestore(
            isAwaitingTransientResolution: true,
            baseline: baseline,
            current: current
        )
    }

    mutating func resolveTransientRestore() {
        transientResolution = .none
    }

    mutating func completeStableObservation(fingerprint: ClipboardTextFingerprint?) {
        lastStableTextFingerprint = fingerprint
        transientResolution = .none
    }
}
