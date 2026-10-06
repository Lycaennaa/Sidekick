import AppKit
import CoreAudio
import Foundation

enum MicrophoneActivitySnapshot: Equatable {
    struct Device: Equatable {
        let id: AudioDeviceID
        let name: String
        let applicationNames: [String]?
        let inputGainPercentage: Int?

        init(
            id: AudioDeviceID,
            name: String,
            applicationNames: [String]? = nil,
            inputGain: Float32? = nil
        ) {
            self.id = id
            self.name = name
            self.applicationNames = applicationNames?.isEmpty == true ? nil : applicationNames
            self.inputGainPercentage = Self.normalizedInputGainPercentage(inputGain)
        }

        private static func normalizedInputGainPercentage(_ inputGain: Float32?) -> Int? {
            guard let inputGain, inputGain.isFinite, inputGain >= 0, inputGain <= 1 else {
                return nil
            }
            return Int((Double(inputGain) * 100).rounded())
        }
    }

    case active(Device)
    case inactive
    case unavailable
}
struct CoreAudioMicrophoneActivityProvider {
    typealias ApplicationNameResolver = (pid_t) -> String?

    private struct ApplicationAttribution {
        let namesByDevice: [AudioDeviceID: [String]]
        let unknownDeviceIDs: Set<AudioDeviceID>
        let globallyUnknown: Bool

        func names(for deviceID: AudioDeviceID) -> [String]? {
            guard !globallyUnknown, !unknownDeviceIDs.contains(deviceID) else { return nil }
            return namesByDevice[deviceID]
        }
    }

    private struct DeviceQuery {
        let deviceIDs: [AudioDeviceID]
        let applicationAttribution: ApplicationAttribution
        let activityQueryFailed: Bool
    }

    private let applicationNameResolver: ApplicationNameResolver
    private let coreAudioReader: CoreAudioMicrophoneActivityReader

    init(
        applicationNameResolver: @escaping ApplicationNameResolver = {
            CoreAudioMicrophoneActivityProvider.defaultApplicationName(for: $0)
        },
        coreAudioReader: CoreAudioMicrophoneActivityReader = .init()
    ) {
        self.applicationNameResolver = applicationNameResolver
        self.coreAudioReader = coreAudioReader
    }

    static func applicationNamesByDevice(
        from processes: [(deviceIDs: [AudioDeviceID], applicationName: String)]
    ) -> [AudioDeviceID: [String]] {
        var namesByDevice: [AudioDeviceID: Set<String>] = [:]
        for process in processes {
            for deviceID in process.deviceIDs {
                namesByDevice[deviceID, default: []].insert(process.applicationName)
            }
        }
        return namesByDevice.mapValues { $0.sorted() }
    }

    func snapshot() -> MicrophoneActivitySnapshot {
        switch activeInputDeviceIDs() {
        case let .some(query):
            let result = activity(in: query)
            guard result == .unavailable else { return result }
        case .none:
            break
        }

        guard let deviceIDs = coreAudioReader.objectIDs(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal
        ) else {
            return .unavailable
        }
        return activity(in: DeviceQuery(
            deviceIDs: deviceIDs,
            applicationAttribution: ApplicationAttribution(
                namesByDevice: [:],
                unknownDeviceIDs: [],
                globallyUnknown: true
            ),
            activityQueryFailed: false
        ))
    }

    private func activity(in query: DeviceQuery) -> MicrophoneActivitySnapshot {
        guard !query.deviceIDs.isEmpty else {
            return query.activityQueryFailed ? .unavailable : .inactive
        }

        var deviceIDs = query.deviceIDs
        if let defaultID = coreAudioReader.defaultInputDeviceID(),
           let index = deviceIDs.firstIndex(of: defaultID) {
            deviceIDs.remove(at: index)
            deviceIDs.insert(defaultID, at: 0)
        }

        var activityQueryFailed = query.activityQueryFailed
        for deviceID in deviceIDs {
            guard let isActive = inputStreamIsActive(deviceID: deviceID) else {
                activityQueryFailed = true
                continue
            }
            guard isActive else { continue }
            guard let name = coreAudioReader.deviceName(deviceID: deviceID) else {
                activityQueryFailed = true
                continue
            }
            return .active(.init(
                id: deviceID,
                name: name,
                applicationNames: query.applicationAttribution.names(for: deviceID),
                inputGain: coreAudioReader.propertyFloat32(
                    objectID: deviceID,
                    selector: kAudioDevicePropertyVolumeScalar,
                    scope: kAudioObjectPropertyScopeInput
                )
            ))
        }
        return activityQueryFailed ? .unavailable : .inactive
    }

    private func activeInputDeviceIDs() -> DeviceQuery? {
        guard let processIDs = coreAudioReader.objectIDs(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        ) else {
            return nil
        }

        var deviceIDs: [AudioDeviceID] = []
        var activeProcesses: [(deviceIDs: [AudioDeviceID], applicationName: String)] = []
        var unknownDeviceIDs = Set<AudioDeviceID>()
        var seenDeviceIDs = Set<AudioDeviceID>()
        var activityQueryFailed = false
        var attributionGloballyUnknown = false
        for processID in processIDs {
            guard let isRunningInput = processIsRunningInput(processID: processID) else {
                activityQueryFailed = true
                attributionGloballyUnknown = true
                continue
            }
            guard isRunningInput else { continue }
            guard let processDeviceIDs = coreAudioReader.objectIDs(
                objectID: processID,
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeInput
            ) else {
                activityQueryFailed = true
                attributionGloballyUnknown = true
                continue
            }
            let inputDeviceIDs = processDeviceIDs.map { AudioDeviceID($0) }
            guard !inputDeviceIDs.isEmpty else {
                activityQueryFailed = true
                attributionGloballyUnknown = true
                continue
            }
            for deviceID in inputDeviceIDs where seenDeviceIDs.insert(deviceID).inserted {
                deviceIDs.append(deviceID)
            }
            guard let applicationName = processApplicationName(processObjectID: processID) else {
                unknownDeviceIDs.formUnion(inputDeviceIDs)
                continue
            }
            activeProcesses.append((deviceIDs: inputDeviceIDs, applicationName: applicationName))
        }
        return DeviceQuery(
            deviceIDs: deviceIDs,
            applicationAttribution: ApplicationAttribution(
                namesByDevice: Self.applicationNamesByDevice(from: activeProcesses),
                unknownDeviceIDs: unknownDeviceIDs,
                globallyUnknown: attributionGloballyUnknown
            ),
            activityQueryFailed: activityQueryFailed
        )
    }

    private func inputStreamIsActive(deviceID: AudioDeviceID) -> Bool? {
        guard let streamIDs = coreAudioReader.objectIDs(
            objectID: deviceID,
            selector: kAudioDevicePropertyStreams,
            scope: kAudioObjectPropertyScopeInput
        ) else {
            return nil
        }

        var queryFailed = false
        for streamID in streamIDs {
            guard let direction = coreAudioReader.propertyUInt32(
                objectID: streamID,
                selector: kAudioStreamPropertyDirection
            ) else {
                queryFailed = true
                continue
            }
            guard direction == 1 else { continue }
            guard let isActive = coreAudioReader.propertyUInt32(
                objectID: streamID,
                selector: kAudioStreamPropertyIsActive
            ) else {
                queryFailed = true
                continue
            }
            if isActive != 0 { return true }
        }
        return queryFailed ? nil : false
    }

    private func processIsRunningInput(processID: AudioObjectID) -> Bool? {
        coreAudioReader.propertyUInt32(
            objectID: processID,
            selector: kAudioProcessPropertyIsRunningInput
        ).map { $0 != 0 }
    }

    private func processApplicationName(processObjectID: AudioObjectID) -> String? {
        guard let processIdentifier = coreAudioReader.processIdentifier(processObjectID: processObjectID) else {
            return nil
        }
        return applicationName(for: processIdentifier)
    }

    func applicationName(for processIdentifier: pid_t) -> String? {
        Self.normalizedApplicationName(applicationNameResolver(processIdentifier))
    }

    private static func normalizedApplicationName(_ name: String?) -> String? {
        guard let name else { return nil }
        let normalizedName = name
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedName.isEmpty ? nil : normalizedName
    }

    private static func defaultApplicationName(for processIdentifier: pid_t) -> String? {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            return nil
        }

        for value in [application.localizedName, application.bundleIdentifier] {
            let name = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty {
                return name
            }
        }
        return nil
    }
}
