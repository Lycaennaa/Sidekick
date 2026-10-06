import CoreAudio
import Foundation

struct AudioOutputDevice: Equatable, Identifiable {
    let id: AudioDeviceID
    let name: String
    let isDefault: Bool
    let supportsTemporaryMute: Bool
}

enum CoreAudioOutputVolumeError: Error, Equatable, LocalizedError {
    case invalidVolume
    case controlUnavailable
    case propertyNotSettable
    case discoveryFailed(OSStatus)
    case readFailed(OSStatus)
    case writeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidVolume:
            "Volume must be finite and between 0 and 1."
        case .controlUnavailable:
            "Output device has no required mute or volume control."
        case .propertyNotSettable:
            "Output device control is not writable."
        case let .discoveryFailed(status):
            "Couldn’t enumerate output devices (Core Audio status \(status))."
        case let .readFailed(status):
            "Couldn’t read output control (Core Audio status \(status))."
        case let .writeFailed(status):
            "Couldn’t write output control (Core Audio status \(status))."
        }
    }
}
struct CoreAudioOutputVolumeStore: Sendable {
    private static let outputScope = kAudioDevicePropertyScopeOutput
    private static let mainElement = kAudioObjectPropertyElementMain

    private let access: any CoreAudioOutputPropertyAccess
    private let discovery: any CoreAudioOutputDeviceDiscovery

    init(
        access: any CoreAudioOutputPropertyAccess = LiveCoreAudioOutputPropertyAccess(),
        discovery: any CoreAudioOutputDeviceDiscovery = LiveCoreAudioOutputDeviceDiscovery()
    ) {
        self.access = access
        self.discovery = discovery
    }

    func outputDevices() throws -> [AudioOutputDevice] {
        let defaultDeviceID = try discoveryValue(discovery.defaultOutputDeviceID())
        let deviceIDs = try discoveryValue(discovery.deviceIDs())
        var devices: [AudioOutputDevice] = []

        for deviceID in deviceIDs {
            let streams = try discoveryValue(discovery.outputStreamIDs(for: deviceID))
            guard !streams.isEmpty else { continue }
            let name: String?
            do {
                name = try discoveryValue(discovery.name(for: deviceID))
            } catch {
                name = nil
            }
            devices.append(
                AudioOutputDevice(
                    id: deviceID,
                    name: name ?? "Output \(deviceID)",
                    isDefault: deviceID == defaultDeviceID,
                    supportsTemporaryMute: supportsTemporaryMute(deviceID)
                )
            )
        }

        return devices.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault {
                return lhs.isDefault
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func discoveryValue<Value>(
        _ result: Result<Value, CoreAudioPropertyStatus>
    ) throws -> Value {
        switch result {
        case let .success(value):
            return value
        case let .failure(error):
            throw CoreAudioOutputVolumeError.discoveryFailed(error.rawValue)
        }
    }

    func volume(for deviceID: AudioDeviceID) throws -> Float32 {
        guard hasScalarVolume(deviceID) else {
            throw CoreAudioOutputVolumeError.controlUnavailable
        }
        switch access.readFloat(
            objectID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: Self.outputScope,
            element: Self.mainElement
        ) {
        case let .success(value):
            guard value.isFinite, (0...1).contains(value) else {
                throw CoreAudioOutputVolumeError.readFailed(kAudioHardwareBadDeviceError)
            }
            return value
        case let .failure(status):
            throw CoreAudioOutputVolumeError.readFailed(status.rawValue)
        }
    }

    func setVolume(_ value: Float32, for deviceID: AudioDeviceID) throws {
        guard value.isFinite, (0...1).contains(value) else {
            throw CoreAudioOutputVolumeError.invalidVolume
        }
        guard hasScalarVolume(deviceID) else {
            throw CoreAudioOutputVolumeError.controlUnavailable
        }
        guard access.isPropertySettable(
            objectID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: Self.outputScope,
            element: Self.mainElement
        ) else {
            throw CoreAudioOutputVolumeError.propertyNotSettable
        }
        switch access.writeFloat(
            value,
            objectID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: Self.outputScope,
            element: Self.mainElement
        ) {
        case .success:
            return
        case let .failure(status):
            throw CoreAudioOutputVolumeError.writeFailed(status.rawValue)
        }
    }

    func isMuted(for deviceID: AudioDeviceID) throws -> Bool {
        guard hasMuteControl(deviceID) else {
            throw CoreAudioOutputVolumeError.controlUnavailable
        }
        switch access.readUInt32(
            objectID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: Self.outputScope,
            element: Self.mainElement
        ) {
        case let .success(value):
            return value != 0
        case let .failure(status):
            throw CoreAudioOutputVolumeError.readFailed(status.rawValue)
        }
    }

    func setMuted(_ muted: Bool, for deviceID: AudioDeviceID) throws {
        guard hasMuteControl(deviceID) else {
            throw CoreAudioOutputVolumeError.controlUnavailable
        }
        guard access.isPropertySettable(
            objectID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: Self.outputScope,
            element: Self.mainElement
        ) else {
            throw CoreAudioOutputVolumeError.propertyNotSettable
        }
        switch access.writeUInt32(
            muted ? 1 : 0,
            objectID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: Self.outputScope,
            element: Self.mainElement
        ) {
        case .success:
            return
        case let .failure(status):
            throw CoreAudioOutputVolumeError.writeFailed(status.rawValue)
        }
    }

    private func supportsTemporaryMute(_ deviceID: AudioDeviceID) -> Bool {
        guard hasMuteControl(deviceID),
              access.isPropertySettable(
                  objectID: deviceID,
                  selector: kAudioDevicePropertyMute,
                  scope: Self.outputScope,
                  element: Self.mainElement
              ),
              hasScalarVolume(deviceID),
              access.isPropertySettable(
                  objectID: deviceID,
                  selector: kAudioDevicePropertyVolumeScalar,
                  scope: Self.outputScope,
                  element: Self.mainElement
              ) else {
            return false
        }
        return true
    }

    private func hasScalarVolume(_ deviceID: AudioDeviceID) -> Bool {
        access.hasProperty(
            objectID: deviceID,
            selector: kAudioDevicePropertyVolumeScalar,
            scope: Self.outputScope,
            element: Self.mainElement
        )
    }

    private func hasMuteControl(_ deviceID: AudioDeviceID) -> Bool {
        access.hasProperty(
            objectID: deviceID,
            selector: kAudioDevicePropertyMute,
            scope: Self.outputScope,
            element: Self.mainElement
        )
    }
}
