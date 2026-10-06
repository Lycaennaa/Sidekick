import Carbon.HIToolbox

@MainActor final class GlobalHotKey {
    struct Shortcut: Sendable {
        fileprivate let keyCode: UInt32
        fileprivate let modifiers: UInt32
        fileprivate let identifier: EventHotKeyID

        static let webPClipboard = Self(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(cmdKey | optionKey | shiftKey),
            identifier: EventHotKeyID(signature: 0x4D574350, id: 1)
        )
        static let cleanMarkdown = Self(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: UInt32(cmdKey | optionKey | shiftKey),
            identifier: EventHotKeyID(signature: 0x4D574350, id: 2)
        )
        static let screenshotClipboard = Self(
            keyCode: UInt32(kVK_ANSI_4),
            modifiers: UInt32(cmdKey | optionKey | shiftKey),
            identifier: EventHotKeyID(signature: 0x4D574350, id: 3)
        )
    }

    private let shortcut: Shortcut
    private let action: @MainActor @Sendable () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    init(shortcut: Shortcut, action: @escaping @MainActor @Sendable () -> Void) {
        self.shortcut = shortcut
        self.action = action
    }

    func start() -> OSStatus {
        guard eventHandler == nil, hotKey == nil else { return noErr }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                let owner = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    guard status == noErr,
                          identifier.signature == owner.shortcut.identifier.signature,
                          identifier.id == owner.shortcut.identifier.id else {
                        return OSStatus(eventNotHandledErr)
                    }
                    owner.action()
                    return noErr
                }

            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else { return handlerStatus }

        let registrationStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            shortcut.identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        if registrationStatus != noErr {
            stop()
        }
        return registrationStatus
    }

    func stop() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}
