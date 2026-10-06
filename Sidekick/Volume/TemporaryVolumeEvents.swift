struct TemporaryVolumeToastContent: Equatable {
    let message: String
    let symbolName: String
}

extension TemporaryVolumeEvent {
    var toastContent: TemporaryVolumeToastContent {
        switch self {
        case let .muted(_, duration):
            return TemporaryVolumeToastContent(
                message: "Output muted for \(TemporaryVolumeDuration.label(for: duration))",
                symbolName: "speaker.slash"
            )
        case let .scheduled(_, startDelay, duration):
            let startDelayLabel = TemporaryVolumeDuration.label(for: startDelay)
            let durationLabel = TemporaryVolumeDuration.label(for: duration)
            return TemporaryVolumeToastContent(
                message: "Mute scheduled in \(startDelayLabel) for \(durationLabel)",
                symbolName: "timer"
            )
        case .cancelled:
            return TemporaryVolumeToastContent(
                message: "Scheduled mute canceled",
                symbolName: "timer.circle"
            )
        case .restoring:
            return TemporaryVolumeToastContent(
                message: "Restoring volume",
                symbolName: "speaker.wave.2"
            )
        case .restored:
            return TemporaryVolumeToastContent(
                message: "Volume restored",
                symbolName: "speaker.wave.2"
            )
        }
    }
}
