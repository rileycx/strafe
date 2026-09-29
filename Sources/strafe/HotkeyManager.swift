import Carbon.HIToolbox
import Foundation

/// Registers global hotkeys via Carbon's `RegisterEventHotKey` and routes them
/// to the switch engine. Defaults: ctrl+opt+left / ctrl+opt+right.
///
/// This is a working implementation (not stubbed). Carbon hotkeys are still the
/// simplest reliable way to grab a system-wide key combo without a full event
/// tap, and they do not require Accessibility permission.
///
/// **Toggleable.** Ctrl+Option+Left/Right is also a common chord for
/// third-party window-tiling tools (and macOS's own tiling shortcuts), and
/// Carbon registrations can conflict with other owners of the same shortcut. Since
/// this is a separate mechanism from the gesture tap (SPEC §2), it can be
/// switched off independently via `HotkeyManager.enabled` / the menu-bar
/// "Space-switch hotkeys" item / `strafe hotkeys off` — leaving the swipe
/// speedup itself untouched.
@MainActor
final class HotkeyManager {
    private let engine: SwitchEngine

    private var eventHandler: EventHandlerRef?
    private var leftHotKey: EventHotKeyRef?
    private var rightHotKey: EventHotKeyRef?
    private var controlLeftHotKey: EventHotKeyRef?
    private var controlRightHotKey: EventHotKeyRef?

    /// Registration is not proof of delivery: native Space shortcuts must be disabled.
    var controlArrowsRegistered: Bool { controlLeftHotKey != nil && controlRightHotKey != nil }

    private var settingsObserver: (any NSObjectProtocol)?

    nonisolated private static let settingsChanged = Notification.Name(
        "com.rileycx.strafe.hotkeysChanged"
    )

    // Distinct ids so the handler knows which combo fired.
    private static let signature: OSType = {
        // 'SNAP'
        let chars: [UInt8] = [0x53, 0x4E, 0x41, 0x50]
        return chars.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()
    private static let leftID: UInt32 = 1
    private static let rightID: UInt32 = 2
    private static let controlLeftID: UInt32 = 3
    private static let controlRightID: UInt32 = 4

    init(engine: SwitchEngine) {
        self.engine = engine
    }

    func start() {
        guard settingsObserver == nil else { return }
        settingsObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.settingsChanged, object: Preferences.domain, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settingsObserver != nil else { return }
                self.applyStoredState()
            }
        }
        applyStoredState()
    }

    func stop() {
        if let settingsObserver {
            DistributedNotificationCenter.default().removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        unregister()
    }

    /// Install the Carbon event handler and register both hotkeys.
    func register() {
        installHandlerIfNeeded()
        guard eventHandler != nil else { return }

        let ctrlOpt = UInt32(controlKey | optionKey)
        if leftHotKey == nil {
            leftHotKey = registerHotKey(keyCode: UInt32(kVK_LeftArrow), id: Self.leftID, modifiers: ctrlOpt)
        }
        if rightHotKey == nil {
            rightHotKey = registerHotKey(keyCode: UInt32(kVK_RightArrow), id: Self.rightID, modifiers: ctrlOpt)
        }
    }

    private func registerControlArrows() {
        guard !controlArrowsRegistered else { return }
        controlLeftHotKey = registerHotKey(
            keyCode: UInt32(kVK_LeftArrow), id: Self.controlLeftID, modifiers: UInt32(controlKey))
        controlRightHotKey = registerHotKey(
            keyCode: UInt32(kVK_RightArrow), id: Self.controlRightID, modifiers: UInt32(controlKey))
        // A failed pair must not leave only one direction captured. Applying the
        // setting again retries, while the original Ctrl+Option pair stays intact.
        if !controlArrowsRegistered { unregisterControlArrows() }
    }

    private func unregisterControlArrows() {
        if let controlLeftHotKey { UnregisterEventHotKey(controlLeftHotKey) }
        if let controlRightHotKey { UnregisterEventHotKey(controlRightHotKey) }
        controlLeftHotKey = nil
        controlRightHotKey = nil
    }

    /// Unregister hotkeys and remove the handler.
    func unregister() {
        unregisterControlArrows()
        if let leftHotKey { UnregisterEventHotKey(leftHotKey) }
        if let rightHotKey { UnregisterEventHotKey(rightHotKey) }
        leftHotKey = nil
        rightHotKey = nil
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    /// Register or unregister to match the persisted setting. Safe to call
    /// repeatedly (both `register`/`unregister` are no-ops in the direction
    /// that's already satisfied, aside from a redundant handler install check).
    func applyStoredState() {
        // Refresh the cache after another process changes the shared preference.
        Preferences.store.synchronize()
        if HotkeyManager.enabled {
            register()
            if Self.controlArrowsEnabled && eventHandler != nil {
                registerControlArrows()
            } else {
                unregisterControlArrows()
            }
        } else {
            unregister()
        }
    }

    // MARK: - Persistence

    /// `nonisolated` so the CLI (`strafe hotkeys [on|off]`, no run loop, no
    /// main actor) can read/write this without hopping actors.

    /// The one `UserDefaults` key this setting uses, following the same
    /// convention as `TransitionSpeed.storageKey`.
    nonisolated static let enabledStorageKey = "spaceHotkeysEnabled"

    /// The persisted setting. An absent key — a fresh install — means `true`,
    /// so strafe's out-of-the-box behaviour is unchanged by this feature.
    /// `object(forKey:)` rather than `bool(forKey:)` so "never set" is
    /// distinguishable from a stored `false`.
    nonisolated static var enabled: Bool {
        Preferences.store.object(forKey: enabledStorageKey) as? Bool ?? true
    }

    nonisolated static let controlArrowsStorageKey = "controlArrowHotkeysEnabled"

    /// Opt-in: native macOS Space shortcuts otherwise own these combinations.
    nonisolated static var controlArrowsEnabled: Bool {
        Preferences.store.bool(forKey: controlArrowsStorageKey)
    }

    nonisolated static let controlArrowSetup = """
        In System Settings > Keyboard > Keyboard Shortcuts > Mission Control, \
        turn off “Move left a space” and “Move right a space”. strafe does not \
        change these macOS settings for you.

        Control-arrow switching requires strafe to be running, Accessibility \
        permission, and Space-switch hotkeys to be enabled. Control+Option+arrows \
        remain available too.

        If you quit, disable, or uninstall strafe, turn those two macOS shortcuts \
        back on to restore native Control-arrow switching. Removing strafe’s \
        preferences does not restore macOS shortcuts.
        """

    nonisolated static func persist(controlArrowsEnabled: Bool) {
        Preferences.store.set(controlArrowsEnabled, forKey: controlArrowsStorageKey)
        notifySettingsChanged()
    }

    nonisolated static func persist(enabled: Bool) {
        Preferences.store.set(enabled, forKey: enabledStorageKey)
        notifySettingsChanged()
    }

    nonisolated private static func notifySettingsChanged() {
        // Flush before notifying so a resident app cannot read the previous value.
        Preferences.store.synchronize()
        DistributedNotificationCenter.default().postNotificationName(
            settingsChanged, object: Preferences.domain, userInfo: nil, deliverImmediately: true
        )
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
                guard hotKeyID.signature == HotkeyManager.signature else { return OSStatus(eventNotHandledErr) }

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
            eventHandler = nil
            FileHandle.standardError.write(
                Data("[HotkeyManager] InstallEventHandler failed (status \(status))\n".utf8))
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
            FileHandle.standardError.write(
                Data("[HotkeyManager] RegisterEventHotKey failed (status \(status)) for id \(id)\n".utf8)
            )
            return nil
        }
        return ref
    }

    private func handle(id: UInt32) {
        let direction: SwitchDirection
        switch id {
        case Self.leftID, Self.controlLeftID: direction = .left
        case Self.rightID, Self.controlRightID: direction = .right
        default: return
        }
        do {
            try engine.switchSpace(direction)
        } catch {
            FileHandle.standardError.write(
                Data("[HotkeyManager] switchSpace failed: \(error)\n".utf8)
            )
        }
    }
}
