import Carbon

final class HotkeyManager: @unchecked Sendable {
    var onTogglePlay: (() -> Void)?
    var onTapTempo: (() -> Void)?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var isRegistered = false

    private let startHotKeyID = EventHotKeyID(signature: 0x4D54524F, id: 1)
    private let tapHotKeyID = EventHotKeyID(signature: 0x4D54524F, id: 2)

    private let startKeyCode: UInt32 = 46
    private let tapKeyCode: UInt32 = 17

    func register() {
        guard !isRegistered else { return }
        isRegistered = true

        let modifiers = UInt32(cmdKey | optionKey | controlKey)
        registerSingle(id: startHotKeyID, keyCode: startKeyCode, modifiers: modifiers, ref: &hotKeyRefs[1])
        registerSingle(id: tapHotKeyID, keyCode: tapKeyCode, modifiers: modifiers, ref: &hotKeyRefs[2])

        installEventHandler()
    }

    func unregister() {
        guard isRegistered else { return }
        isRegistered = false
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func registerSingle(id: EventHotKeyID, keyCode: UInt32, modifiers: UInt32, ref: inout EventHotKeyRef?) {
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status != noErr {
            print("Hotkey registration failed with status: \(status)")
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    OSType(kEventParamDirectObject),
                    OSType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr else { return err }

                if hotKeyID.id == 1 {
                    manager.onTogglePlay?()
                } else if hotKeyID.id == 2 {
                    manager.onTapTempo?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            nil
        )
    }
}
