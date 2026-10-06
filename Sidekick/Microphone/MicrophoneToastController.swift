import AppKit

@MainActor
final class MicrophoneToastController {
    private enum Suppression {
        case untilActivityChange
        case until(Date)
    }
    private static let inactiveGracePeriod: TimeInterval = 2
    private static let maximumVisibleApplicationNames = 8

    private weak var toastPresentationCoordinator: ToastPresentationCoordinator?
    private let settings: AppSettings
    private let activitySnapshot: () -> MicrophoneActivitySnapshot
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private var timer: Timer?
    private var generation: UInt64 = 0
    private var activeDevice: MicrophoneActivitySnapshot.Device?
    private var inactiveSinceUptime: TimeInterval?
    private var suppression: Suppression?

    init(
        toastPresentationCoordinator: ToastPresentationCoordinator,
        settings: AppSettings,
        now: @escaping () -> Date = Date.init,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        activitySnapshot: @escaping () -> MicrophoneActivitySnapshot = {
            CoreAudioMicrophoneActivityProvider().snapshot()
        }
    ) {
        self.toastPresentationCoordinator = toastPresentationCoordinator
        self.settings = settings
        self.now = now
        self.uptime = uptime
        self.activitySnapshot = activitySnapshot
    }

    func start() {
        guard settings.microphoneToastEnabled, timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        suppression = nil
        deactivate()
    }

    func applySettings() {
        if settings.microphoneToastEnabled {
            start()
        } else {
            stop()
        }
    }

    func hideMicrophoneToastUntilNextActivityChange() {
        suppression = .untilActivityChange
        toastPresentationCoordinator?.hideMicrophone()
    }

    func hideMicrophoneToast(for duration: TimeInterval) {
        guard duration > 0, duration.isFinite else { return }
        suppression = .until(now().addingTimeInterval(duration))
        toastPresentationCoordinator?.hideMicrophone()
    }

    func showMicrophoneToast() {
        guard settings.microphoneToastEnabled else { return }
        suppression = nil
        refresh()
    }

    func refresh() {
        guard settings.microphoneToastEnabled else {
            deactivate()
            return
        }
        switch activitySnapshot() {
        case let .active(device):
            inactiveSinceUptime = nil
            let activityChanged = activeDevice.map {
                $0.id != device.id || $0.name != device.name
            } ?? true
            let presentationChanged = activeDevice != device
            activeDevice = device
            if activityChanged {
                clearActivityChangeSuppression()
            }
            guard !shouldSuppressToast() else { return }

            let needsPresentation = activityChanged
                || presentationChanged
                || toastPresentationCoordinator?.isMicrophonePresented != true
            guard needsPresentation else { return }

            let summary = Self.microphoneSummary(
                deviceName: device.name,
                applicationNames: device.applicationNames ?? []
            )

            generation &+= 1
            toastPresentationCoordinator?.presentMicrophone(
                ToastModel(
                    generation: generation,
                    presentationStyle: .generic,
                    summary: summary,
                    detail: nil,
                    icon: NSImage(
                        systemSymbolName: "mic.fill",
                        accessibilityDescription: "Microphone active"
                    ),
                    footer: device.inputGainPercentage.map { "Input gain: \($0)%" }
                ),
                duration: .infinity,
                onUserDismiss: { [weak self] in
                    self?.microphoneToastWasDismissedByUser()
                }
            )
        case .inactive:
            guard activeDevice != nil else { return }
            let currentUptime = uptime()
            let inactiveSinceUptime = self.inactiveSinceUptime ?? currentUptime
            self.inactiveSinceUptime = inactiveSinceUptime
            guard currentUptime - inactiveSinceUptime >= Self.inactiveGracePeriod else { return }
            clearActivityChangeSuppression()
            deactivate()
        case .unavailable:
            inactiveSinceUptime = nil
            return
        }
    }

    private static func microphoneSummary(
        deviceName: String,
        applicationNames: [String]
    ) -> String {
        guard !applicationNames.isEmpty else {
            return "Microphone: \"\(deviceName)\" active"
        }

        var lines = ["Microphone: \"\(deviceName)\" active in:"]
        let visibleNames = applicationNames.prefix(Self.maximumVisibleApplicationNames)
        lines.append(contentsOf: visibleNames)

        let hiddenCount = applicationNames.count - visibleNames.count
        if hiddenCount > 0 {
            lines.append("+\(hiddenCount) more")
        }
        return lines.joined(separator: "\n")
    }

    private func clearActivityChangeSuppression() {
        if case .untilActivityChange = suppression {
            suppression = nil
        }
    }

    private func shouldSuppressToast() -> Bool {
        guard let suppression else { return false }
        switch suppression {
        case .untilActivityChange:
            return true
        case let .until(deadline):
            guard deadline > now() else {
                self.suppression = nil
                return false
            }
            return true
        }
    }

    private func microphoneToastWasDismissedByUser() {
        suppression = .untilActivityChange
    }

    private func deactivate() {
        activeDevice = nil
        inactiveSinceUptime = nil
        toastPresentationCoordinator?.hideMicrophone()
    }
}

@MainActor
final class MicrophoneToastMenu: NSObject {
    static let hideOptions: [(title: String, interval: TimeInterval)] = [
        ("15 Minutes", 15 * 60),
        ("1 Hour", 60 * 60),
        ("3 Hours", 3 * 60 * 60)
    ]

    let menu: NSMenu

    private let onHide: (TimeInterval?) -> Void
    private let onShow: () -> Void

    init(
        onHide: @escaping (TimeInterval?) -> Void,
        onShow: @escaping () -> Void
    ) {
        self.onHide = onHide
        self.onShow = onShow
        menu = NSMenu()
        super.init()
        installMenu()
    }

    private func installMenu() {
        menu.autoenablesItems = false
        let untilActivityChangeItem = NSMenuItem(
            title: "Until Next Activity Change",
            action: #selector(selectHide(_:)),
            keyEquivalent: ""
        )
        untilActivityChangeItem.target = self
        menu.addItem(untilActivityChangeItem)

        for option in Self.hideOptions {
            let item = NSMenuItem(
                title: "Hide for \(option.title)",
                action: #selector(selectHide(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = NSNumber(value: option.interval)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let showItem = NSMenuItem(
            title: "Show Now",
            action: #selector(showMicrophoneToast),
            keyEquivalent: ""
        )
        showItem.target = self
        menu.addItem(showItem)
    }

    @objc private func selectHide(_ sender: NSMenuItem) {
        onHide((sender.representedObject as? NSNumber)?.doubleValue)
    }

    @objc private func showMicrophoneToast() {
        onShow()
    }
}
