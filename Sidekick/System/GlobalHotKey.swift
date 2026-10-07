import Carbon.HIToolbox

@MainActor final class GlobalHotKey {
    struct Shortcut: Sendable, Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
        let keyName: String

        private static let signature = OSType(0x4D574350)
        private static let supportedModifierMask = UInt32(cmdKey | optionKey | shiftKey | controlKey)
        private static let requiredModifierMask = UInt32(cmdKey | optionKey | controlKey)
        private static let reservedKeyCodes: Set<UInt32> = [
            UInt32(kVK_ANSI_A),
            UInt32(kVK_ANSI_C),
            UInt32(kVK_ANSI_F),
            UInt32(kVK_ANSI_R),
            UInt32(kVK_ANSI_W),
            UInt32(kVK_Return),
            UInt32(kVK_ANSI_KeypadEnter),
            UInt32(kVK_Escape)
        ]
        private static let commandOnlyMenuKeyCodes: Set<UInt32> = [
            UInt32(kVK_ANSI_Q),
            UInt32(kVK_ANSI_X),
            UInt32(kVK_ANSI_V)
        ]

        static let webPClipboard = Self(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(cmdKey | optionKey | shiftKey),
            keyName: "C"
        )
        static let cleanMarkdown = Self(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: UInt32(cmdKey | optionKey | shiftKey),
            keyName: "M"
        )
        static let screenshotSaveAndClipboard = Self(
            keyCode: UInt32(kVK_ANSI_5),
            modifiers: UInt32(cmdKey | optionKey | shiftKey),
            keyName: "5"
        )

        private init(keyCode: UInt32, modifiers: UInt32, keyName: String) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.keyName = keyName
        }

        static func recorded(keyCode: UInt32, modifiers: UInt32, keyName: String) -> Self? {
            let normalizedName = keyName.uppercased()
            guard keyCode <= 127,
                  !reservedKeyCodes.contains(keyCode),
                  modifiers & ~supportedModifierMask == 0,
                  modifiers & requiredModifierMask != 0,
                  normalizedName.count == 1,
                  let scalar = normalizedName.unicodeScalars.first,
                  (65...90).contains(scalar.value) || (48...57).contains(scalar.value) else {
                return nil
            }
            let shortcut = Self(keyCode: keyCode, modifiers: modifiers, keyName: normalizedName)
            return shortcut.conflictsWithApplicationMenuShortcut ? nil : shortcut
        }

        var displayName: String {
            var name = ""
            if modifiers & UInt32(cmdKey) != 0 { name += "⌘" }
            if modifiers & UInt32(optionKey) != 0 { name += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { name += "⇧" }
            if modifiers & UInt32(controlKey) != 0 { name += "⌃" }
            return name + keyName
        }

        func hasSameChord(as other: Self) -> Bool {
            keyCode == other.keyCode && modifiers == other.modifiers
        }

        var conflictsWithApplicationMenuShortcut: Bool {
            modifiers == UInt32(cmdKey) && Self.commandOnlyMenuKeyCodes.contains(keyCode)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.hasSameChord(as: rhs) && lhs.keyName == rhs.keyName
        }
    }

    private static var nextIdentifier: UInt32 = 100
    private let shortcut: Shortcut
    private let identifier: EventHotKeyID
    private let action: @MainActor @Sendable () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    init(shortcut: Shortcut, action: @escaping @MainActor @Sendable () -> Void) {
        self.shortcut = shortcut
        self.action = action
        identifier = EventHotKeyID(signature: 0x4D574350, id: Self.nextIdentifier)
        Self.nextIdentifier &+= 1
    }

    func hasShortcut(_ shortcut: Shortcut) -> Bool {
        self.shortcut.hasSameChord(as: shortcut)
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
                          identifier.signature == owner.identifier.signature,
                          identifier.id == owner.identifier.id else {
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
            identifier,
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
