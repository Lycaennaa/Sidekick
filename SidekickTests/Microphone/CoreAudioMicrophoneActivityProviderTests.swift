import CoreAudio
import XCTest

final class CoreAudioMicrophoneActivityProviderTests: XCTestCase {
    func testDefaultProviderCanReadCurrentMicrophoneActivity() {
        let snapshot = CoreAudioMicrophoneActivityProvider().snapshot()

        XCTAssertNotEqual(snapshot, .unavailable)
        if case let .active(device) = snapshot {
            XCTAssertFalse(device.name.isEmpty)
            if let applicationNames = device.applicationNames {
                XCTAssertTrue(applicationNames.allSatisfy { !$0.isEmpty })
            }
        }
    }

    func testApplicationNameResolverAttributesInjectedProcess() {
        let processIdentifier = pid_t(42)
        let provider = CoreAudioMicrophoneActivityProvider(
            applicationNameResolver: { identifier in
                identifier == processIdentifier ? "Zoom" : nil
            }
        )

        XCTAssertEqual(provider.applicationName(for: processIdentifier), "Zoom")
    }

    func testApplicationNamesAreAggregatedPerDeviceRegardlessOfProcessOrder() {
        let deviceID = AudioDeviceID(42)
        let processes: [(deviceIDs: [AudioDeviceID], applicationName: String)] = [
            (deviceIDs: [deviceID], applicationName: "Zoom"),
            (deviceIDs: [deviceID], applicationName: "Slack"),
            (deviceIDs: [deviceID], applicationName: "Zoom")
        ]
        let expectedNames = ["Slack", "Zoom"]

        XCTAssertEqual(
            CoreAudioMicrophoneActivityProvider.applicationNamesByDevice(from: processes)[deviceID],
            expectedNames
        )
        XCTAssertEqual(
            CoreAudioMicrophoneActivityProvider.applicationNamesByDevice(
                from: Array(processes.reversed())
            )[deviceID],
            expectedNames
        )
    }

    func testSnapshotAggregatesAndNormalizesNamesFromMultipleActiveProcesses() {
        let firstProcessID = AudioObjectID(1)
        let secondProcessID = AudioObjectID(2)
        let deviceID = AudioDeviceID(42)
        let streamID = AudioObjectID(100)
        let provider = makeProvider(
            objectIDs: [
                .init(
                    objectID: AudioObjectID(kAudioObjectSystemObject),
                    selector: kAudioHardwarePropertyProcessObjectList,
                    scope: kAudioObjectPropertyScopeGlobal
                ): [firstProcessID, secondProcessID],
                .init(
                    objectID: firstProcessID,
                    selector: kAudioProcessPropertyDevices,
                    scope: kAudioObjectPropertyScopeInput
                ): [AudioObjectID(deviceID)],
                .init(
                    objectID: secondProcessID,
                    selector: kAudioProcessPropertyDevices,
                    scope: kAudioObjectPropertyScopeInput
                ): [AudioObjectID(deviceID)],
                .init(
                    objectID: AudioObjectID(deviceID),
                    selector: kAudioDevicePropertyStreams,
                    scope: kAudioObjectPropertyScopeInput
                ): [streamID]
            ],
            propertyValues: [
                .init(objectID: firstProcessID, selector: kAudioProcessPropertyIsRunningInput): 1,
                .init(objectID: secondProcessID, selector: kAudioProcessPropertyIsRunningInput): 1,
                .init(objectID: streamID, selector: kAudioStreamPropertyDirection): 1,
                .init(objectID: streamID, selector: kAudioStreamPropertyIsActive): 1
            ],
            propertyFloat32Values: [
                .init(
                    objectID: deviceID,
                    selector: kAudioDevicePropertyVolumeScalar,
                    scope: kAudioObjectPropertyScopeInput
                ): 0.75
            ],
            deviceNames: [deviceID: "Studio Mic"],
            processIdentifiers: [firstProcessID: pid_t(41), secondProcessID: pid_t(42)],
            applicationNameResolver: { identifier in
                switch identifier {
                case 41: "Zoom\nSpoof"
                case 42: "Slack"
                default: nil
                }
            }
        )

        guard case let .active(device) = provider.snapshot() else {
            XCTFail("Expected active microphone")
            return
        }
        XCTAssertEqual(device.applicationNames, ["Slack", "Zoom Spoof"])
        XCTAssertEqual(device.inputGainPercentage, 75)
    }

    func testUnresolvedApplicationNameLeavesActiveDeviceAttributionUnknown() {
        let processID = AudioObjectID(1)
        let deviceID = AudioDeviceID(42)
        let streamID = AudioObjectID(100)
        let provider = makeProvider(
            objectIDs: [
                .init(
                    objectID: AudioObjectID(kAudioObjectSystemObject),
                    selector: kAudioHardwarePropertyProcessObjectList,
                    scope: kAudioObjectPropertyScopeGlobal
                ): [processID],
                .init(
                    objectID: processID,
                    selector: kAudioProcessPropertyDevices,
                    scope: kAudioObjectPropertyScopeInput
                ): [AudioObjectID(deviceID)],
                .init(
                    objectID: AudioObjectID(deviceID),
                    selector: kAudioDevicePropertyStreams,
                    scope: kAudioObjectPropertyScopeInput
                ): [streamID]
            ],
            propertyValues: [
                .init(objectID: processID, selector: kAudioProcessPropertyIsRunningInput): 1,
                .init(objectID: streamID, selector: kAudioStreamPropertyDirection): 1,
                .init(objectID: streamID, selector: kAudioStreamPropertyIsActive): 1
            ],
            deviceNames: [deviceID: "Studio Mic"],
            processIdentifiers: [processID: pid_t(42)],
            applicationNameResolver: { _ in nil }
        )

        guard case let .active(device) = provider.snapshot() else {
            XCTFail("Expected active microphone")
            return
        }
        XCTAssertEqual(device.id, deviceID)
        XCTAssertEqual(device.name, "Studio Mic")
        XCTAssertNil(device.applicationNames)
    }
    func testUnresolvedAttributionIsIsolatedPerDevice() {
        let knownProcessID = AudioObjectID(1)
        let unresolvedProcessID = AudioObjectID(2)
        let knownDeviceID = AudioDeviceID(42)
        let unresolvedDeviceID = AudioDeviceID(43)
        let knownStreamID = AudioObjectID(100)
        let unresolvedStreamID = AudioObjectID(101)
        let provider = makeProvider(
            objectIDs: [
                .init(
                    objectID: AudioObjectID(kAudioObjectSystemObject),
                    selector: kAudioHardwarePropertyProcessObjectList,
                    scope: kAudioObjectPropertyScopeGlobal
                ): [knownProcessID, unresolvedProcessID],
                .init(
                    objectID: knownProcessID,
                    selector: kAudioProcessPropertyDevices,
                    scope: kAudioObjectPropertyScopeInput
                ): [AudioObjectID(knownDeviceID)],
                .init(
                    objectID: unresolvedProcessID,
                    selector: kAudioProcessPropertyDevices,
                    scope: kAudioObjectPropertyScopeInput
                ): [AudioObjectID(unresolvedDeviceID)],
                .init(
                    objectID: AudioObjectID(knownDeviceID),
                    selector: kAudioDevicePropertyStreams,
                    scope: kAudioObjectPropertyScopeInput
                ): [knownStreamID],
                .init(
                    objectID: AudioObjectID(unresolvedDeviceID),
                    selector: kAudioDevicePropertyStreams,
                    scope: kAudioObjectPropertyScopeInput
                ): [unresolvedStreamID]
            ],
            propertyValues: [
                .init(objectID: knownProcessID, selector: kAudioProcessPropertyIsRunningInput): 1,
                .init(objectID: unresolvedProcessID, selector: kAudioProcessPropertyIsRunningInput): 1,
                .init(objectID: knownStreamID, selector: kAudioStreamPropertyDirection): 1,
                .init(objectID: knownStreamID, selector: kAudioStreamPropertyIsActive): 1,
                .init(objectID: unresolvedStreamID, selector: kAudioStreamPropertyDirection): 1,
                .init(objectID: unresolvedStreamID, selector: kAudioStreamPropertyIsActive): 1
            ],
            deviceNames: [knownDeviceID: "Known Mic", unresolvedDeviceID: "Other Mic"],
            processIdentifiers: [knownProcessID: pid_t(41), unresolvedProcessID: pid_t(42)],
            applicationNameResolver: { identifier in
                identifier == 41 ? "Zoom" : nil
            }
        )

        guard case let .active(device) = provider.snapshot() else {
            XCTFail("Expected active microphone")
            return
        }
        XCTAssertEqual(device.id, knownDeviceID)
        XCTAssertEqual(device.applicationNames, ["Zoom"])
    }

    func testProcessQueryFailureDoesNotExposePartialApplicationAttribution() {
        let knownProcessID = AudioObjectID(1)
        let failedProcessID = AudioObjectID(2)
        let deviceID = AudioDeviceID(42)
        let streamID = AudioObjectID(100)
        let provider = makeProvider(
            objectIDs: [
                .init(
                    objectID: AudioObjectID(kAudioObjectSystemObject),
                    selector: kAudioHardwarePropertyProcessObjectList,
                    scope: kAudioObjectPropertyScopeGlobal
                ): [knownProcessID, failedProcessID],
                .init(
                    objectID: knownProcessID,
                    selector: kAudioProcessPropertyDevices,
                    scope: kAudioObjectPropertyScopeInput
                ): [AudioObjectID(deviceID)],
                .init(
                    objectID: AudioObjectID(deviceID),
                    selector: kAudioDevicePropertyStreams,
                    scope: kAudioObjectPropertyScopeInput
                ): [streamID]
            ],
            propertyValues: [
                .init(objectID: knownProcessID, selector: kAudioProcessPropertyIsRunningInput): 1,
                .init(objectID: failedProcessID, selector: kAudioProcessPropertyIsRunningInput): 1,
                .init(objectID: streamID, selector: kAudioStreamPropertyDirection): 1,
                .init(objectID: streamID, selector: kAudioStreamPropertyIsActive): 1
            ],
            deviceNames: [deviceID: "Studio Mic"],
            processIdentifiers: [knownProcessID: pid_t(42)],
            applicationNameResolver: { identifier in
                identifier == 42 ? "Zoom" : nil
            }
        )

        guard case let .active(device) = provider.snapshot() else {
            XCTFail("Expected active microphone")
            return
        }
        XCTAssertEqual(device.id, deviceID)
        XCTAssertNil(device.applicationNames)
    }

    func testStreamFallbackLeavesApplicationAttributionUnknown() {
        let deviceID = AudioDeviceID(42)
        let streamID = AudioObjectID(100)
        let provider = makeProvider(
            objectIDs: [
                .init(
                    objectID: AudioObjectID(kAudioObjectSystemObject),
                    selector: kAudioHardwarePropertyDevices,
                    scope: kAudioObjectPropertyScopeGlobal
                ): [AudioObjectID(deviceID)],
                .init(
                    objectID: AudioObjectID(deviceID),
                    selector: kAudioDevicePropertyStreams,
                    scope: kAudioObjectPropertyScopeInput
                ): [streamID]
            ],
            propertyValues: [
                .init(objectID: streamID, selector: kAudioStreamPropertyDirection): 1,
                .init(objectID: streamID, selector: kAudioStreamPropertyIsActive): 1
            ],
            deviceNames: [deviceID: "Studio Mic"]
        )

        guard case let .active(device) = provider.snapshot() else {
            XCTFail("Expected active microphone")
            return
        }
        XCTAssertEqual(device.id, deviceID)
        XCTAssertEqual(device.name, "Studio Mic")
        XCTAssertNil(device.applicationNames)
    }

    func testInputGainCanonicalizesToDisplayedPercentage() {
        let lower = MicrophoneActivitySnapshot.Device(
            id: AudioDeviceID(42),
            name: "Studio Mic",
            inputGain: 0.749
        )
        let upper = MicrophoneActivitySnapshot.Device(
            id: AudioDeviceID(42),
            name: "Studio Mic",
            inputGain: 0.751
        )
        let invalid = MicrophoneActivitySnapshot.Device(
            id: AudioDeviceID(42),
            name: "Studio Mic",
            inputGain: 1.01
        )

        XCTAssertEqual(lower.inputGainPercentage, 75)
        XCTAssertEqual(upper.inputGainPercentage, 75)
        XCTAssertEqual(lower, upper)
        XCTAssertNil(invalid.inputGainPercentage)
    }

    private struct ObjectIDsRequest: Hashable {
        let objectID: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
    }

    private struct PropertyRequest: Hashable {
        let objectID: AudioObjectID
        let selector: AudioObjectPropertySelector
    }

    private struct PropertyFloat32Request: Hashable {
        let objectID: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
    }

    private func makeProvider(
        objectIDs: [ObjectIDsRequest: [AudioObjectID]],
        propertyValues: [PropertyRequest: UInt32],
        propertyFloat32Values: [PropertyFloat32Request: Float32] = [:],
        deviceNames: [AudioDeviceID: String],
        processIdentifiers: [AudioObjectID: pid_t] = [:],
        applicationNameResolver: @escaping CoreAudioMicrophoneActivityProvider.ApplicationNameResolver = { _ in nil }
    ) -> CoreAudioMicrophoneActivityProvider {
        let dependencies = CoreAudioMicrophoneActivityReader.Dependencies(
            objectIDs: { objectID, selector, scope in
                objectIDs[ObjectIDsRequest(objectID: objectID, selector: selector, scope: scope)]
            },
            propertyUInt32: { objectID, selector in
                propertyValues[PropertyRequest(objectID: objectID, selector: selector)]
            },
            propertyFloat32: { objectID, selector, scope in
                propertyFloat32Values[PropertyFloat32Request(
                    objectID: objectID,
                    selector: selector,
                    scope: scope
                )]
            },
            defaultInputDeviceID: { nil },
            deviceName: { deviceNames[$0] },
            processIdentifier: { processIdentifiers[$0] }
        )
        return CoreAudioMicrophoneActivityProvider(
            applicationNameResolver: applicationNameResolver,
            coreAudioReader: CoreAudioMicrophoneActivityReader(dependencies: dependencies)
        )
    }
}
extension CoreAudioMicrophoneActivityProviderTests {
    func testDefaultReaderReadsDefaultInputGainWhenDeviceExposesIt() throws {
        let reader = CoreAudioMicrophoneActivityReader()
        let deviceID = try XCTUnwrap(reader.defaultInputDeviceID())
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else {
            throw XCTSkip("The default input device exposes no input volume control.")
        }

        let gain = try XCTUnwrap(
            reader.propertyFloat32(
                objectID: deviceID,
                selector: kAudioDevicePropertyVolumeScalar,
                scope: kAudioObjectPropertyScopeInput
            )
        )
        XCTAssertTrue(gain.isFinite)
        XCTAssertGreaterThanOrEqual(gain, 0)
        XCTAssertLessThanOrEqual(gain, 1)
    }
}
