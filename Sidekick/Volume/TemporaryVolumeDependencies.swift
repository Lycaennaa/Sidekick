import CoreAudio
import Foundation

struct TemporaryVolumeDependencies {
    typealias DeviceReader = @MainActor @Sendable () throws -> [AudioOutputDevice]
    typealias VolumeReader = @MainActor @Sendable (AudioDeviceID) throws -> Float32
    typealias VolumeWriter = @MainActor @Sendable (Float32, AudioDeviceID) throws -> Void
    typealias MuteReader = @MainActor @Sendable (AudioDeviceID) throws -> Bool
    typealias MuteWriter = @MainActor @Sendable (Bool, AudioDeviceID) throws -> Void
    typealias Sleeper = @MainActor @Sendable (Duration) async throws -> Void

    let devices: DeviceReader
    let readVolume: VolumeReader
    let setVolume: VolumeWriter
    let readMuted: MuteReader
    let setMuted: MuteWriter
    let sleep: Sleeper

    init(
        devices: @escaping DeviceReader,
        readVolume: @escaping VolumeReader,
        setVolume: @escaping VolumeWriter,
        readMuted: @escaping MuteReader,
        setMuted: @escaping MuteWriter,
        sleep: @escaping Sleeper = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.devices = devices
        self.readVolume = readVolume
        self.setVolume = setVolume
        self.readMuted = readMuted
        self.setMuted = setMuted
        self.sleep = sleep
    }

    static func live() -> Self {
        let store = CoreAudioOutputVolumeStore()
        return Self(
            devices: { try store.outputDevices() },
            readVolume: { try store.volume(for: $0) },
            setVolume: { try store.setVolume($0, for: $1) },
            readMuted: { try store.isMuted(for: $0) },
            setMuted: { try store.setMuted($0, for: $1) }
        )
    }
}
