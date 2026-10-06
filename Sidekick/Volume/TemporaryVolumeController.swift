import CoreAudio
import Foundation

@MainActor
final class TemporaryVolumeController {
    private struct MuteState {
        let originalVolume: Float32
        let originalMuted: Bool
        var restorationVolume: Float32
        var expectedVolume: Float32
        var expectedMuted: Bool
    }

    private enum DeviceOperationPhase {
        case scheduled
        case muted(MuteState)
        case restoring(MuteState)
    }

    private final class DeviceOperation {
        var phase: DeviceOperationPhase
        var generation: UInt64
        var task: Task<Void, Never>?

        init(phase: DeviceOperationPhase, generation: UInt64, task: Task<Void, Never>? = nil) {
            self.phase = phase
            self.generation = generation
            self.task = task
        }
    }

    private static let fadeStepCount = 20
    private static let fadeStepDuration = Duration.milliseconds(50)
    private static let volumeTolerance: Float32 = 0.005

    private let dependencies: TemporaryVolumeDependencies
    private var operations: [AudioDeviceID: DeviceOperation] = [:]
    private var nextGeneration: UInt64 = 0

    var onStateChange: (() -> Void)?
    var onFailure: ((TemporaryVolumeError) -> Void)?
    var onEvent: ((TemporaryVolumeEvent) -> Void)?

    init(dependencies: TemporaryVolumeDependencies = .live()) {
        self.dependencies = dependencies
    }

    func outputDevices() -> [AudioOutputDevice] {
        do {
            return try dependencies.devices()
        } catch {
            reportFailure(error)
            return []
        }
    }

    func hasActiveTimer(for deviceID: AudioDeviceID) -> Bool {
        operations[deviceID] != nil
    }

    func hasPendingTimer(for deviceID: AudioDeviceID) -> Bool {
        guard let operation = operations[deviceID] else { return false }
        if case .scheduled = operation.phase { return true }
        return false
    }

    func hasActiveTimers() -> Bool {
        !operations.isEmpty
    }

    func restoreAll() {
        for deviceID in Array(operations.keys) {
            restoreNow(deviceID: deviceID)
        }
    }

    @discardableResult
    func scheduleMute(
        deviceID: AudioDeviceID,
        startDelay: TimeInterval,
        duration: TimeInterval
    ) -> Bool {
        guard isValidDuration(startDelay), isValidDuration(duration), startDelay > 0 else {
            report(.invalidDuration)
            return false
        }
        if let operation = operations[deviceID] {
            guard case .scheduled = operation.phase else {
                report(.operationAlreadyActive)
                return false
            }
            operation.task?.cancel()
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        operations[deviceID] = DeviceOperation(phase: .scheduled, generation: generation)
        let sleep = dependencies.sleep
        let task = Task { @MainActor [weak self] in
            do {
                try await sleep(.seconds(startDelay))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  let operation = self.operations[deviceID],
                  operation.generation == generation,
                  case .scheduled = operation.phase else {
                return
            }
            self.operations.removeValue(forKey: deviceID)
            self.onStateChange?()
            _ = self.mute(deviceID: deviceID, for: duration)
        }
        operations[deviceID]?.task = task
        onStateChange?()
        onEvent?(.scheduled(deviceID: deviceID, startDelay: startDelay, duration: duration))
        return true
    }

    @discardableResult
    func mute(deviceID: AudioDeviceID, for duration: TimeInterval) -> Bool {
        guard isValidDuration(duration) else {
            report(.invalidDuration)
            return false
        }

        let existingOperation = operations[deviceID]
        let state: MuteState
        if let existingOperation {
            switch existingOperation.phase {
            case .scheduled:
                do {
                    let volume = try dependencies.readVolume(deviceID)
                    let muted = try dependencies.readMuted(deviceID)
                    state = MuteState(
                        originalVolume: volume,
                        originalMuted: muted,
                        restorationVolume: volume,
                        expectedVolume: volume,
                        expectedMuted: true
                    )
                } catch {
                    reportFailure(error)
                    return false
                }
            case let .muted(previous), let .restoring(previous):
                state = previous
            }
        } else {
            do {
                let volume = try dependencies.readVolume(deviceID)
                let muted = try dependencies.readMuted(deviceID)
                state = MuteState(
                    originalVolume: volume,
                    originalMuted: muted,
                    restorationVolume: volume,
                    expectedVolume: volume,
                    expectedMuted: true
                )
            } catch {
                reportFailure(error)
                return false
            }
        }

        do {
            try dependencies.setMuted(true, deviceID)
        } catch {
            reportFailure(error)
            return false
        }

        existingOperation?.task?.cancel()
        nextGeneration &+= 1
        let generation = nextGeneration
        operations[deviceID] = DeviceOperation(phase: .muted(state), generation: generation)
        scheduleExpiry(for: deviceID, duration: duration, generation: generation)
        onStateChange?()
        onEvent?(.muted(deviceID: deviceID, duration: duration))
        return true
    }

    func restoreNow(deviceID: AudioDeviceID) {
        guard let operation = operations[deviceID] else { return }
        operation.task?.cancel()

        switch operation.phase {
        case .scheduled:
            operations.removeValue(forKey: deviceID)
            onStateChange?()
            onEvent?(.cancelled(deviceID: deviceID))
        case let .muted(state), let .restoring(state):
            nextGeneration &+= 1
            var restoringState = state
            restoringState.restorationVolume = state.originalVolume
            restoringState.expectedVolume = state.originalVolume
            restoringState.expectedMuted = true
            operation.generation = nextGeneration
            operation.phase = .restoring(restoringState)
            operation.task = nil
            beginRestoration(deviceID: deviceID, generation: operation.generation, force: true)
        }
    }

    func stop() {
        for deviceID in Array(operations.keys) {
            guard let operation = operations[deviceID] else { continue }
            operation.task?.cancel()
            switch operation.phase {
            case .scheduled:
                operations.removeValue(forKey: deviceID)
            case let .muted(state), let .restoring(state):
                operation.phase = .restoring(state)
                operation.task = nil
                let errors = restoreSynchronously(state, deviceID: deviceID)
                for error in errors {
                    report(.coreAudio(error))
                }
                if errors.isEmpty {
                    operations.removeValue(forKey: deviceID)
                }
            }
        }
        onStateChange?()
    }

    private func prepareFade(deviceID: AudioDeviceID, generation: UInt64) {
        guard let operation = operations[deviceID],
              operation.generation == generation,
              case let .restoring(state) = operation.phase else {
            return
        }

        do {
            try dependencies.setVolume(0, deviceID)
        } catch {
            pauseAfterFailure(deviceID: deviceID, generation: generation, error: error)
            return
        }

        do {
            try dependencies.setMuted(false, deviceID)
        } catch {
            let muteError = coreAudioError(error)
            do {
                try dependencies.setVolume(state.restorationVolume, deviceID)
            } catch {
                report(.coreAudio(coreAudioError(error)))
            }
            pauseAfterFailure(deviceID: deviceID, generation: generation, error: muteError)
            return
        }

        var updatedState = state
        updatedState.expectedVolume = 0
        updatedState.expectedMuted = false
        operation.phase = .restoring(updatedState)
        scheduleFade(deviceID: deviceID, generation: generation)
    }

    private func scheduleFade(deviceID: AudioDeviceID, generation: UInt64) {
        let sleep = dependencies.sleep
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            for step in 1...Self.fadeStepCount {
                do {
                    try await sleep(Self.fadeStepDuration)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let operation = self.operations[deviceID],
                      operation.generation == generation,
                      case let .restoring(state) = operation.phase else {
                    return
                }

                let currentVolume: Float32
                let currentlyMuted: Bool
                do {
                    currentVolume = try self.dependencies.readVolume(deviceID)
                    currentlyMuted = try self.dependencies.readMuted(deviceID)
                } catch {
                    self.pauseAfterFailure(deviceID: deviceID, generation: generation, error: error)
                    return
                }
                guard !currentlyMuted,
                      currentlyMuted == state.expectedMuted,
                      Self.matches(currentVolume, state.expectedVolume) else {
                    self.operations.removeValue(forKey: deviceID)
                    self.onStateChange?()
                    return
                }

                let progress = Float32(step) / Float32(Self.fadeStepCount)
                let nextVolume = state.restorationVolume * progress
                do {
                    try self.dependencies.setVolume(nextVolume, deviceID)
                } catch {
                    self.pauseAfterFailure(deviceID: deviceID, generation: generation, error: error)
                    return
                }
                var updatedState = state
                updatedState.expectedVolume = nextVolume
                operation.phase = .restoring(updatedState)
            }

            guard let operation = self.operations[deviceID],
                  operation.generation == generation else {
                return
            }
            self.operations.removeValue(forKey: deviceID)
            self.onStateChange?()
            self.onEvent?(.restored(deviceID: deviceID))
        }
        operations[deviceID]?.task = task
    }

    private func pauseAfterFailure(
        deviceID: AudioDeviceID,
        generation: UInt64,
        error: Error
    ) {
        guard let operation = operations[deviceID],
              operation.generation == generation else {
            return
        }
        operation.task = nil
        report(.coreAudio(coreAudioError(error)))
    }

    private func reportFailure(_ error: Error) {
        report(.coreAudio(coreAudioError(error)))
    }

    private func coreAudioError(_ error: Error) -> CoreAudioOutputVolumeError {
        error as? CoreAudioOutputVolumeError ?? .controlUnavailable
    }

    private func report(_ error: TemporaryVolumeError) {
        onFailure?(error)
    }

    private func isValidDuration(_ duration: TimeInterval) -> Bool {
        TemporaryVolumeDuration.isValidInterval(duration)
    }

    private static func matches(_ lhs: Float32, _ rhs: Float32) -> Bool {
        abs(lhs - rhs) <= volumeTolerance
    }
}
extension TemporaryVolumeController {
    private func restoreSynchronously(
        _ state: MuteState,
        deviceID: AudioDeviceID
    ) -> [CoreAudioOutputVolumeError] {
        var errors: [CoreAudioOutputVolumeError] = []
        do {
            try dependencies.setVolume(state.originalVolume, deviceID)
        } catch {
            errors.append(coreAudioError(error))
        }
        do {
            try dependencies.setMuted(state.originalMuted, deviceID)
        } catch {
            errors.append(coreAudioError(error))
        }
        return errors
    }

    private func scheduleExpiry(
        for deviceID: AudioDeviceID,
        duration: TimeInterval,
        generation: UInt64
    ) {
        let sleep = dependencies.sleep
        let task = Task { @MainActor [weak self] in
            do {
                try await sleep(.seconds(duration))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.beginRestoration(deviceID: deviceID, generation: generation, force: false)
        }
        operations[deviceID]?.task = task
    }

    private func beginRestoration(
        deviceID: AudioDeviceID,
        generation: UInt64,
        force: Bool
    ) {
        guard let operation = operations[deviceID], operation.generation == generation else {
            return
        }
        let state: MuteState
        switch operation.phase {
        case let .muted(value), let .restoring(value):
            state = value
        case .scheduled:
            return
        }

        let currentVolume: Float32
        let currentlyMuted: Bool
        do {
            currentVolume = try dependencies.readVolume(deviceID)
            currentlyMuted = try dependencies.readMuted(deviceID)
        } catch {
            pauseAfterFailure(deviceID: deviceID, generation: generation, error: error)
            return
        }

        if !force, !currentlyMuted {
            operations.removeValue(forKey: deviceID)
            onStateChange?()
            onEvent?(.restored(deviceID: deviceID))
            return
        }

        if state.originalMuted {
            do {
                try dependencies.setMuted(true, deviceID)
            } catch {
                pauseAfterFailure(deviceID: deviceID, generation: generation, error: error)
                return
            }
            operations.removeValue(forKey: deviceID)
            onStateChange?()
            onEvent?(.restored(deviceID: deviceID))
            return
        }

        var updatedState = state
        if !force, !Self.matches(currentVolume, state.expectedVolume) {
            updatedState.restorationVolume = currentVolume
        }
        updatedState.expectedVolume = currentVolume
        updatedState.expectedMuted = currentlyMuted
        operation.phase = .restoring(updatedState)
        onEvent?(.restoring(deviceID: deviceID))
        prepareFade(deviceID: deviceID, generation: generation)
    }
}
