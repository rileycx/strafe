import Carbon.HIToolbox
import Foundation

/// Registers global hotkeys via Carbon's `RegisterEventHotKey` and routes them
/// to the switch engine. Defaults: ctrl+opt+left / ctrl+opt+right.
///
/// This is a working implementation (not stubbed). Carbon hotkeys are still the
/// simplest reliable way to grab a system-wide key combo without a full event
/// tap, and they do not require Accessibility permission.
@MainActor
final class HotkeyManager {
    private let engine: SwitchEngine

    private var eventHandler: EventHandlerRef?
    private var leftHotKey: EventHotKeyRef?
    private var rightHotKey: EventHotKeyRef?

    // Distinct ids so the handler knows which combo fired.
    private static let signature: OSType = {
        // 'SNAP'
        let chars: [UInt8] = [0x53, 0x4E, 0x41, 0x50]
        return chars.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()
    private static let leftID: UInt32 = 1
    private static let rightID: UInt32 = 2

    init(engine: SwitchEngine) {
        self.engine = engine
    }

    /// Install the Carbon event handler and register both hotkeys.
    func register() {
        installHandlerIfNeeded()

        let ctrlOpt = UInt32(controlKey | optionKey)
        leftHotKey = registerHotKey(keyCode: UInt32(kVK_LeftArrow), id: Self.leftID, modifiers: ctrlOpt)
        rightHotKey = registerHotKey(keyCode: UInt32(kVK_RightArrow), id: Self.rightID, modifiers: ctrlOpt)
    }

    /// Unregister hotkeys and remove the handler.
    func unregister() {
        if let leftHotKey { UnregisterEventHotKey(leftHotKey) }
        if let rightHotKey { UnregisterEventHotKey(rightHotKey) }
        leftHotKey = nil
        rightHotKey = nil
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    // MARK: - Internals

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userInfo -> OSStatus in
                guard let userInfo, let event else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                // Carbon calls back on the main thread; hop to the main actor.
                MainActor.assumeIsolated {
                    manager.handle(id: hotKeyID.id)
                }
                return noErr
            },
            1,
            &spec,
            userInfo,
            &eventHandler
        )
        if status != noErr {
            SwitchDiagnostics.log("[HotkeyManager] InstallEventHandler failed (status \(status))")
        }
    }

    private func registerHotKey(keyCode: UInt32, id: UInt32, modifiers: UInt32) -> EventHotKeyRef? {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr else {
            SwitchDiagnostics.log("[HotkeyManager] RegisterEventHotKey failed (status \(status)) for id \(id)")
            return nil
        }
        return ref
    }

    private func handle(id: UInt32) {
        let direction: SwitchDirection
        switch id {
        case Self.leftID: direction = .left
        case Self.rightID: direction = .right
        default: return
        }
        do {
            try engine.switchSpace(direction)
        } catch {
            SwitchDiagnostics.log("[HotkeyManager] switchSpace enqueue failed: \(error)")
        }
    }
}
