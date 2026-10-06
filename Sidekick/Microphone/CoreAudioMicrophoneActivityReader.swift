import CoreAudio
import Foundation

struct CoreAudioMicrophoneActivityReader {
    typealias ObjectIDsReader = (
        AudioObjectID,
        AudioObjectPropertySelector,
        AudioObjectPropertyScope
    ) -> [AudioObjectID]?
    typealias PropertyUInt32Reader = (AudioObjectID, AudioObjectPropertySelector) -> UInt32?
    typealias PropertyFloat32Reader = (
        AudioObjectID,
        AudioObjectPropertySelector,
        AudioObjectPropertyScope
    ) -> Float32?
    typealias DefaultInputDeviceIDReader = () -> AudioDeviceID?
    typealias DeviceNameReader = (AudioDeviceID) -> String?
    typealias ProcessIdentifierReader = (AudioObjectID) -> pid_t?

    struct Dependencies {
        let objectIDs: ObjectIDsReader
        let propertyUInt32: PropertyUInt32Reader
        let propertyFloat32: PropertyFloat32Reader
        let defaultInputDeviceID: DefaultInputDeviceIDReader
        let deviceName: DeviceNameReader
        let processIdentifier: ProcessIdentifierReader

        init(
            objectIDs: @escaping ObjectIDsReader,
            propertyUInt32: @escaping PropertyUInt32Reader,
            propertyFloat32: @escaping PropertyFloat32Reader,
            defaultInputDeviceID: @escaping DefaultInputDeviceIDReader,
            deviceName: @escaping DeviceNameReader,
            processIdentifier: @escaping ProcessIdentifierReader
        ) {
            self.objectIDs = objectIDs
            self.propertyUInt32 = propertyUInt32
            self.propertyFloat32 = propertyFloat32
            self.defaultInputDeviceID = defaultInputDeviceID
            self.deviceName = deviceName
            self.processIdentifier = processIdentifier
        }
    }

    private let dependencies: Dependencies

    init() {
        self.init(dependencies: Self.makeLiveDependencies())
    }

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func objectIDs(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID]? {
        dependencies.objectIDs(objectID, selector, scope)
    }

    func propertyUInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        dependencies.propertyUInt32(objectID, selector)
    }

    func propertyFloat32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Float32? {
        dependencies.propertyFloat32(objectID, selector, scope)
    }

    func defaultInputDeviceID() -> AudioDeviceID? {
        dependencies.defaultInputDeviceID()
    }

    func deviceName(deviceID: AudioDeviceID) -> String? {
        dependencies.deviceName(deviceID)
    }

    func processIdentifier(processObjectID: AudioObjectID) -> pid_t? {
        dependencies.processIdentifier(processObjectID)
    }

    private static func makeLiveDependencies() -> Dependencies {
        Dependencies(
            objectIDs: { objectID, selector, scope in
                readObjectIDs(objectID: objectID, selector: selector, scope: scope)
            },
            propertyUInt32: { objectID, selector in
                readPropertyUInt32(objectID: objectID, selector: selector)
            },
            propertyFloat32: { objectID, selector, scope in
                readPropertyFloat32(objectID: objectID, selector: selector, scope: scope)
            },
            defaultInputDeviceID: {
                readDefaultInputDeviceID()
            },
            deviceName: { deviceID in
                readDeviceName(deviceID: deviceID)
            },
            processIdentifier: { processObjectID in
                readProcessIdentifier(processObjectID: processObjectID)
            }
        )
    }

    private static func readProcessIdentifier(processObjectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var identifier = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(
            processObjectID,
            &address,
            0,
            nil,
            &size,
            &identifier
        ) == noErr, identifier > 0 else {
            return nil
        }
        return identifier
    }

    private static func readPropertyUInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr else {
            return nil
        }
        return value
    }

    private static func readPropertyFloat32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(objectID, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &value
        ) == noErr, value.isFinite else {
            return nil
        }
        return value
    }

    private static func readObjectIDs(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            objectID,
            &address,
            0,
            nil,
            &size
        ) == noErr else {
            return nil
        }

        let stride = UInt32(MemoryLayout<AudioObjectID>.stride)
        guard size > 0 else { return [] }
        guard size % stride == 0 else { return nil }
        var objectIDs = [AudioObjectID](repeating: 0, count: Int(size / stride))
        let status = objectIDs.withUnsafeMutableBytes { bytes -> OSStatus? in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                baseAddress
            )
        }
        guard let status, status == noErr, size % stride == 0 else { return nil }
        let returnedCount = Int(size / stride)
        guard returnedCount <= objectIDs.count else { return nil }
        return Array(objectIDs.prefix(returnedCount))
    }

    private static func readDefaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &id
        ) == noErr, id != 0 else {
            return nil
        }
        return id
    }

    private static func readDeviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &name
        ) == noErr, let name else {
            return nil
        }
        let value = (name.takeRetainedValue() as String)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
