import CoreAudio
import Foundation

protocol CoreAudioOutputDeviceDiscovery: Sendable {
    func deviceIDs() -> Result<[AudioDeviceID], CoreAudioPropertyStatus>
    func outputStreamIDs(for deviceID: AudioDeviceID) -> Result<[AudioObjectID], CoreAudioPropertyStatus>
    func defaultOutputDeviceID() -> Result<AudioDeviceID?, CoreAudioPropertyStatus>
    func name(for deviceID: AudioDeviceID) -> Result<String?, CoreAudioPropertyStatus>
}

struct LiveCoreAudioOutputDeviceDiscovery: CoreAudioOutputDeviceDiscovery {
    // Reject provider-sized lists beyond the supported device and stream count.
    static let maximumObjectCount: UInt32 = 4_096

    static func objectIDCount(forPropertyDataSize size: UInt32) -> Int? {
        let stride = UInt32(MemoryLayout<AudioObjectID>.stride)
        guard size % stride == 0,
              size / stride <= maximumObjectCount else {
            return nil
        }
        return Int(size / stride)
    }

    static func trimObjectIDs(
        _ objectIDs: inout [AudioObjectID],
        returnedDataSize: UInt32,
        allocatedDataSize: UInt32
    ) -> Bool {
        guard returnedDataSize <= allocatedDataSize,
              let count = objectIDCount(forPropertyDataSize: returnedDataSize),
              count <= objectIDs.count else {
            return false
        }
        objectIDs.removeLast(objectIDs.count - count)
        return true
    }

    func deviceIDs() -> Result<[AudioDeviceID], CoreAudioPropertyStatus> {
        objectIDs(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal
        ).map { values in values.map { AudioDeviceID($0) } }
    }

    func outputStreamIDs(for deviceID: AudioDeviceID) -> Result<[AudioObjectID], CoreAudioPropertyStatus> {
        objectIDs(
            objectID: deviceID,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeOutput
        )
    }

    func defaultOutputDeviceID() -> Result<AudioDeviceID?, CoreAudioPropertyStatus> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else {
            return .failure(CoreAudioPropertyStatus(rawValue: status))
        }
        return .success(deviceID == 0 ? nil : deviceID)
    }

    func name(for deviceID: AudioDeviceID) -> Result<String?, CoreAudioPropertyStatus> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name)
        guard status == noErr else {
            return .failure(CoreAudioPropertyStatus(rawValue: status))
        }
        guard let name else { return .success(nil) }
        let value = name.takeRetainedValue() as String
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(normalized.isEmpty ? nil : normalized)
    }

    private func objectIDs(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Result<[AudioObjectID], CoreAudioPropertyStatus> {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        let sizeStatus = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            return .failure(CoreAudioPropertyStatus(rawValue: sizeStatus))
        }
        guard let count = Self.objectIDCount(forPropertyDataSize: size) else {
            return .failure(CoreAudioPropertyStatus(rawValue: kAudioHardwareIllegalOperationError))
        }
        guard count > 0 else { return .success([]) }

        let allocatedDataSize = size
        var values = [AudioObjectID](repeating: 0, count: count)
        let status = values.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else {
                return kAudioHardwareIllegalOperationError
            }
            return AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                baseAddress
            )
        }
        guard status == noErr else {
            return .failure(CoreAudioPropertyStatus(rawValue: status))
        }
        guard Self.trimObjectIDs(
            &values,
            returnedDataSize: size,
            allocatedDataSize: allocatedDataSize
        ) else {
            return .failure(CoreAudioPropertyStatus(rawValue: kAudioHardwareIllegalOperationError))
        }
        return .success(values)
    }
}
