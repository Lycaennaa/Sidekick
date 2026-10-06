import Foundation

struct ClipboardToastState: Equatable {
    enum Pause: Equatable {
        case until(Date)
        case indefinitely
    }

    enum SuspensionReason: Hashable {
        case screenLocked
        case sessionInactive
        case systemSleeping
    }

    enum Status: Equatable {
        case disabled
        case active
        case paused
        case suspended
        case terminating
    }

    private(set) var enabled: Bool
    private(set) var pause: Pause?
    private(set) var suspensionReasons: Set<SuspensionReason> = []
    private var changeObservation = ClipboardChangeObservationState()
    private(set) var isTerminating = false

    var observedChangeCount: Int? {
        changeObservation.observedChangeCount
    }

    var generation: UInt64 {
        changeObservation.generation
    }

    init(enabled: Bool) {
        self.enabled = enabled
    }

    var status: Status {
        if isTerminating { return .terminating }
        if !enabled { return .disabled }
        if !suspensionReasons.isEmpty { return .suspended }
        if pause != nil { return .paused }
        return .active
    }

    mutating func setEnabled(_ enabled: Bool) -> Bool {
        guard !isTerminating, enabled != self.enabled else { return false }
        self.enabled = enabled
        if !enabled {
            pause = nil
        }
        invalidateMonitoring()
        return true
    }

    mutating func beginPause(until deadline: Date?) -> Bool {
        guard enabled, !isTerminating else { return false }
        pause = deadline.map(Pause.until) ?? .indefinitely
        invalidateMonitoring()
        return true
    }

    mutating func resume() -> Bool {
        guard pause != nil, !isTerminating else { return false }
        pause = nil
        invalidateMonitoring()
        return true
    }

    mutating func expirePause(at date: Date) -> Bool {
        guard case let .until(deadline) = pause, date >= deadline else { return false }
        pause = nil
        invalidateMonitoring()
        return true
    }

    mutating func addSuspension(_ reason: SuspensionReason) -> Bool {
        guard !isTerminating, suspensionReasons.insert(reason).inserted else { return false }
        invalidateMonitoring()
        return true
    }

    mutating func removeSuspension(_ reason: SuspensionReason) -> Bool {
        guard !isTerminating, suspensionReasons.remove(reason) != nil else { return false }
        invalidateMonitoring()
        return true
    }

    mutating func terminate() {
        guard !isTerminating else { return }
        isTerminating = true
        pause = nil
        suspensionReasons.removeAll()
        invalidateMonitoring()
    }

    mutating func seed(changeCount: Int) {
        guard status == .active else { return }
        changeObservation.seed(changeCount: changeCount)
    }

    mutating func observe(changeCount: Int) -> UInt64? {
        guard status == .active else { return nil }
        return changeObservation.observe(changeCount: changeCount)
    }

    func isCurrentGeneration(_ candidate: UInt64) -> Bool {
        !isTerminating && candidate == generation
    }

    private mutating func invalidateMonitoring() {
        changeObservation.invalidate()
    }
}
