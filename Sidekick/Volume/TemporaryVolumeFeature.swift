import CoreAudio

@MainActor
final class TemporaryVolumeFeature {
    let menu: TemporaryVolumeMenu

    private let controller: TemporaryVolumeController

    init(
        onStateChange: @escaping () -> Void,
        onFailure: @escaping (TemporaryVolumeError) -> Void,
        onEvent: @escaping (TemporaryVolumeEvent) -> Void
    ) {
        let controller = TemporaryVolumeController()
        self.controller = controller
        menu = TemporaryVolumeMenu(
            devices: { controller.outputDevices() },
            isActive: { controller.hasActiveTimer(for: $0) },
            isPending: { controller.hasPendingTimer(for: $0) },
            onMute: { deviceID, duration in
                _ = controller.mute(deviceID: deviceID, for: duration)
            },
            onSchedule: { deviceID, startDelay, duration in
                _ = controller.scheduleMute(
                    deviceID: deviceID,
                    startDelay: startDelay,
                    duration: duration
                )
            },
            onRestore: { deviceID in
                controller.restoreNow(deviceID: deviceID)
            }
        )
        controller.onStateChange = onStateChange
        controller.onFailure = onFailure
        controller.onEvent = onEvent
    }

    func refresh() {
        menu.refresh()
    }

    func hasActiveTimers() -> Bool {
        controller.hasActiveTimers()
    }

    func restoreAll() {
        controller.restoreAll()
    }

    func stop() {
        controller.stop()
    }
}
