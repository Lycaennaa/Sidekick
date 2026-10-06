import CoreAudio
struct CoreAudioPropertyStatus: Error, Equatable, Sendable {
    let rawValue: OSStatus
}

protocol CoreAudioOutputPropertyAccess: Sendable {
    func hasProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool

    func isPropertySettable(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool

    func readFloat(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Result<Float32, CoreAudioPropertyStatus>

    func writeFloat(
        _ value: Float32,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Result<Void, CoreAudioPropertyStatus>

    func readUInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Result<UInt32, CoreAudioPropertyStatus>

    func writeUInt32(
        _ value: UInt32,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Result<Void, CoreAudioPropertyStatus>
}

struct LiveCoreAudioOutputPropertyAccess: CoreAudioOutputPropertyAccess {
    func hasProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = address(selector: selector, scope: scope, element: element)
        return AudioObjectHasProperty(objectID, &address)
    }

    func isPropertySettable(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = address(selector: selector, scope: scope, element: element)
        var isSettable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(objectID, &address, &isSettable) == noErr
            && isSettable.boolValue
    }

    func readFloat(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Result<Float32, CoreAudioPropertyStatus> {
        var address = address(selector: selector, scope: scope, element: element)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr
            ? .success(value)
            : .failure(CoreAudioPropertyStatus(rawValue: status))
    }

    func writeFloat(
        _ value: Float32,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Result<Void, CoreAudioPropertyStatus> {
        var address = address(selector: selector, scope: scope, element: element)
        var mutableValue = value
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(objectID, &address, 0, nil, size, &mutableValue)
        return status == noErr
            ? .success(())
            : .failure(CoreAudioPropertyStatus(rawValue: status))
    }

    func readUInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Result<UInt32, CoreAudioPropertyStatus> {
        var address = address(selector: selector, scope: scope, element: element)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr
            ? .success(value)
            : .failure(CoreAudioPropertyStatus(rawValue: status))
    }

    func writeUInt32(
        _ value: UInt32,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Result<Void, CoreAudioPropertyStatus> {
        var address = address(selector: selector, scope: scope, element: element)
        var mutableValue = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(objectID, &address, 0, nil, size, &mutableValue)
        return status == noErr
            ? .success(())
            : .failure(CoreAudioPropertyStatus(rawValue: status))
    }

    private func address(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}
