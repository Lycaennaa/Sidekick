import AppKit
import UniformTypeIdentifiers

@MainActor
final class ClipboardAutoImageConversionController: NSObject {
    static let pollInterval: TimeInterval = 0.25

    private let settings: AppSettings
    private let pasteboard: NSPasteboard
    private let onImageDetected: () -> Void

    private var pollTimer: Timer?
    private var changeObservation = ClipboardChangeObservationState()
    private var enabled = false
    private var started = false

    init(
        settings: AppSettings,
        pasteboard: NSPasteboard = .general,
        onImageDetected: @escaping () -> Void
    ) {
        self.settings = settings
        self.pasteboard = pasteboard
        self.onImageDetected = onImageDetected
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        enabled = settings.automaticImageConversionEnabled
        changeObservation.seed(changeCount: pasteboard.changeCount)
        if enabled {
            startPollTimer()
        }
    }

    func applySettings() {
        guard started else { return }
        synchronizeEnabledState()
    }

    func terminate() {
        guard started else { return }
        started = false
        changeObservation.invalidate()
        stopPollTimer()
    }

    func poll() {
        guard started else { return }
        synchronizeEnabledState()
        guard enabled else { return }

        let changeCount = pasteboard.changeCount
        guard changeObservation.observe(changeCount: changeCount) != nil else { return }
        guard Self.containsConvertibleImage(in: pasteboard, outputFormat: settings.imageOutputFormat) else { return }
        onImageDetected()
    }
    func acknowledgeConvertedChange(changeCount: Int) {
        guard pasteboard.changeCount == changeCount else { return }
        changeObservation.seed(changeCount: changeCount)
    }

    @objc private func pollTimerFired() {
        poll()
    }

    private func synchronizeEnabledState() {
        let shouldEnable = settings.automaticImageConversionEnabled
        guard shouldEnable != enabled else { return }
        enabled = shouldEnable
        changeObservation.seed(changeCount: pasteboard.changeCount)
        if enabled {
            startPollTimer()
        } else {
            stopPollTimer()
        }
    }

    private func startPollTimer() {
        guard pollTimer == nil else { return }
        let timer = Timer(
            timeInterval: Self.pollInterval,
            target: self,
            selector: #selector(pollTimerFired),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private static func containsConvertibleImage(
        in pasteboard: NSPasteboard,
        outputFormat: ClipboardImageFormat
    ) -> Bool {
        guard let items = pasteboard.pasteboardItems else { return false }
        return items.prefix(PasteboardSnapshotPolicy.maximumItems).contains { item in
            item.types.prefix(PasteboardSnapshotPolicy.maximumTypesPerItem).contains { type in
                if type == .fileURL { return true }
                guard PasteboardTypePolicy.isImage(type) else { return false }
                let isOutputFormat = type.rawValue == outputFormat.typeIdentifier
                    || UTType(type.rawValue)?.conforms(to: outputFormat.uniformType) == true
                return !isOutputFormat
            }
        }
    }
}
