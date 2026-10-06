import CoreAudio

enum TemporaryVolumeError: Error, Equatable, LocalizedError {
    case invalidDuration
    case operationAlreadyActive
    case coreAudio(CoreAudioOutputVolumeError)

    var errorDescription: String? {
        switch self {
        case .invalidDuration:
            "Choose a positive duration up to 7 days."
        case .operationAlreadyActive:
            "A mute timer is already active for this output."
        case let .coreAudio(error):
            error.localizedDescription
        }
    }
}

enum TemporaryVolumeEvent: Equatable {
    case muted(deviceID: AudioDeviceID, duration: TimeInterval)
    case scheduled(deviceID: AudioDeviceID, startDelay: TimeInterval, duration: TimeInterval)
    case cancelled(deviceID: AudioDeviceID)
    case restoring(deviceID: AudioDeviceID)
    case restored(deviceID: AudioDeviceID)
}
