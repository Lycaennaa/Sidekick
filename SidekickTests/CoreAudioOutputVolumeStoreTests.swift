import CoreAudio
import Foundation
import XCTest
final class CoreAudioOutputVolumeStoreTests: XCTestCase {
    func testDefaultStoreCanReadAndWriteBackCurrentOutputState() throws {
        let store = CoreAudioOutputVolumeStore()
        guard let device = try? store.outputDevices().first(where: \.isDefault) else {
            throw XCTSkip("No default output device is available.")
        }
        guard device.supportsTemporaryMute else {
            throw XCTSkip("The default output device does not support temporary mute.")
        }

        let currentVolume = try store.volume(for: device.id)
        let currentMute = try store.isMuted(for: device.id)
        try store.setVolume(currentVolume, for: device.id)
        try store.setMuted(currentMute, for: device.id)

        XCTAssertEqual(try store.volume(for: device.id), currentVolume, accuracy: 0.01)
        XCTAssertEqual(try store.isMuted(for: device.id), currentMute)
    }
    func testInjectedPropertyFailureIsSurfaced() {
        var access = StubCoreAudioOutputPropertyAccess()
        access.writeUInt32Status = .failure(CoreAudioPropertyStatus(rawValue: -123))
        let store = CoreAudioOutputVolumeStore(access: access)

        XCTAssertThrowsError(try store.setMuted(true, for: AudioDeviceID(42))) { error in
            XCTAssertEqual(error as? CoreAudioOutputVolumeError, .writeFailed(-123))
        }
    }

    func testInjectedReadFailureIsSurfaced() {
        var access = StubCoreAudioOutputPropertyAccess()
        access.readFloatResult = .failure(CoreAudioPropertyStatus(rawValue: -50))
        let store = CoreAudioOutputVolumeStore(access: access)

        XCTAssertThrowsError(try store.volume(for: AudioDeviceID(42))) { error in
            XCTAssertEqual(error as? CoreAudioOutputVolumeError, .readFailed(-50))
        }
    }

    func testInjectedDiscoveryFiltersInputsAndPutsDefaultBeforeAlphabeticalPeers() throws {
        let discovery = StubCoreAudioOutputDeviceDiscovery(
            availableDeviceIDs: [42, 43, 44],
            outputStreams: [42: [1], 43: [], 44: [2]],
            defaultDeviceID: 42,
            names: [42: "Speakers", 43: "Input", 44: "AirPods"]
        )
        let store = CoreAudioOutputVolumeStore(
            access: StubCoreAudioOutputPropertyAccess(),
            discovery: discovery
        )

        let devices = try store.outputDevices()

        XCTAssertEqual(devices.map(\.id), [42, 44])
        XCTAssertEqual(devices.map(\.name), ["Speakers", "AirPods"])
        XCTAssertTrue(devices[0].isDefault)
        XCTAssertFalse(devices[1].isDefault)
    }

    func testDiscoveryReturnsEmptyListWhenNoDevicesExist() throws {
        let discovery = StubCoreAudioOutputDeviceDiscovery(
            availableDeviceIDs: [],
            outputStreams: [:],
            defaultDeviceID: nil,
            names: [:]
        )
        let store = CoreAudioOutputVolumeStore(discovery: discovery)

        XCTAssertTrue(try store.outputDevices().isEmpty)
    }

    func testDeviceWithoutWritableControlsIsListedAsUnsupported() throws {
        let discovery = StubCoreAudioOutputDeviceDiscovery(
            availableDeviceIDs: [42],
            outputStreams: [42: [1]],
            defaultDeviceID: 42,
            names: [42: "Output"]
        )
        let store = CoreAudioOutputVolumeStore(
            access: StubCoreAudioOutputPropertyAccess(isSettableResult: false),
            discovery: discovery
        )

        XCTAssertFalse(try XCTUnwrap(store.outputDevices().first).supportsTemporaryMute)
    }

    func testDiscoveryRejectsObjectListsAboveSupportedCount() {
        let stride = UInt32(MemoryLayout<AudioObjectID>.stride)
        let maximumCount = LiveCoreAudioOutputDeviceDiscovery.maximumObjectCount

        XCTAssertEqual(
            LiveCoreAudioOutputDeviceDiscovery.objectIDCount(
                forPropertyDataSize: maximumCount * stride
            ),
            Int(maximumCount)
        )
        XCTAssertNil(
            LiveCoreAudioOutputDeviceDiscovery.objectIDCount(
                forPropertyDataSize: (maximumCount + 1) * stride
            )
        )
    }

    func testDiscoveryTrimsObjectListToReturnedPropertySize() {
        let stride = UInt32(MemoryLayout<AudioObjectID>.stride)
        let allocatedDataSize = 4 * stride
        var objectIDs: [AudioObjectID] = [42, 43, 0, 0]

        XCTAssertTrue(
            LiveCoreAudioOutputDeviceDiscovery.trimObjectIDs(
                &objectIDs,
                returnedDataSize: 2 * stride,
                allocatedDataSize: allocatedDataSize
            )
        )
        XCTAssertEqual(objectIDs, [42, 43])

        var unchangedIDs: [AudioObjectID] = [42, 43, 0, 0]
        XCTAssertFalse(
            LiveCoreAudioOutputDeviceDiscovery.trimObjectIDs(
                &unchangedIDs,
                returnedDataSize: 5 * stride,
                allocatedDataSize: allocatedDataSize
            )
        )
        XCTAssertEqual(unchangedIDs, [42, 43, 0, 0])
    }

}

private struct StubCoreAudioOutputPropertyAccess: CoreAudioOutputPropertyAccess {
    var hasPropertyResult = true
    var isSettableResult = true
    var readFloatResult: Result<Float32, CoreAudioPropertyStatus> = .success(0.8)
    var readUInt32Result: Result<UInt32, CoreAudioPropertyStatus> = .success(0)
    var writeFloatStatus: Result<Void, CoreAudioPropertyStatus> = .success(())
    var writeUInt32Status: Result<Void, CoreAudioPropertyStatus> = .success(())

    func hasProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        hasPropertyResult
    }

    func isPropertySettable(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Bool {
        isSettableResult
    }

    func readFloat(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Result<Float32, CoreAudioPropertyStatus> {
        readFloatResult
    }

    func writeFloat(
        _ value: Float32,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Result<Void, CoreAudioPropertyStatus> {
        writeFloatStatus
    }

    func readUInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Result<UInt32, CoreAudioPropertyStatus> {
        readUInt32Result
    }

    func writeUInt32(
        _ value: UInt32,
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement
    ) -> Result<Void, CoreAudioPropertyStatus> {
        writeUInt32Status
    }
}
private struct StubCoreAudioOutputDeviceDiscovery: CoreAudioOutputDeviceDiscovery {
    let availableDeviceIDs: [AudioDeviceID]
    let outputStreams: [AudioDeviceID: [AudioObjectID]]
    let defaultDeviceID: AudioDeviceID?
    let names: [AudioDeviceID: String]

    func deviceIDs() -> Result<[AudioDeviceID], CoreAudioPropertyStatus> {
        .success(availableDeviceIDs)
    }

    func outputStreamIDs(for deviceID: AudioDeviceID) -> Result<[AudioObjectID], CoreAudioPropertyStatus> {
        .success(outputStreams[deviceID] ?? [])
    }

    func defaultOutputDeviceID() -> Result<AudioDeviceID?, CoreAudioPropertyStatus> {
        .success(defaultDeviceID)
    }

    func name(for deviceID: AudioDeviceID) -> Result<String?, CoreAudioPropertyStatus> {
        .success(names[deviceID])
    }
}
