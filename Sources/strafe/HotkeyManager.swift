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
/// Carbon's `RegisterEventHotKey` grabs it system-wide ahead of them. Since
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
    private var settingsObserver: (any NSObjectProtocol)?
    private var registeredShortcuts: [ShortcutAction: KeyboardShortcut] = [:]
    private(set) var registrationError: String?
    private var isRecording = false
    var onStateChanged: (() -> Void)?

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
        let desired = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.compactMap { action in
            action.storedShortcut.map { (action, $0) }
        })
        if desired == registeredShortcuts, registrationError == nil { return }
        unregister()
        registrationError = nil
        if let left = desired[.left], left == desired[.right] {
            registrationError = "Previous Space and Next Space must use different shortcuts."
            return
        }
        guard !desired.isEmpty else { return }
        guard installHandlerIfNeeded() else { return }
        if let shortcut = desired[.left] {
            leftHotKey = registerHotKey(shortcut: shortcut, action: .left, id: Self.leftID)
        }
        if registrationError == nil, let shortcut = desired[.right] {
            rightHotKey = registerHotKey(shortcut: shortcut, action: .right, id: Self.rightID)
        }
        if registrationError != nil { unregister() }
        else { registeredShortcuts = desired }
    }

    /// Unregister hotkeys and remove the handler.
    func unregister() {
        if let leftHotKey { UnregisterEventHotKey(leftHotKey) }
        if let rightHotKey { UnregisterEventHotKey(rightHotKey) }
        leftHotKey = nil
        rightHotKey = nil
        registeredShortcuts = [:]
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
        if HotkeyManager.enabled && !isRecording {
            register()
        } else {
            unregister()
            registrationError = nil
        }
        onStateChanged?()
    }

    /// Suspend our Carbon registrations so the local recorder can see even an
    /// existing strafe shortcut. No event tap or global keyboard monitor is used.
    func setRecording(_ recording: Bool) {
        isRecording = recording
        applyStoredState()
    }

    /// Changes are transactional: a chord owned by another app is rejected and
    /// the previous setting/registrations are restored before returning.
    func updateShortcut(_ shortcut: KeyboardShortcut?, for action: ShortcutAction) -> String? {
        if let error = shortcut?.validationError { return error }
        let other: ShortcutAction = action == .left ? .right : .left
        if let shortcut, shortcut == other.storedShortcut {
            return "That shortcut is already assigned to \(other.title)."
        }
        let previous = action.storedShortcut
        action.persist(shortcut)
        isRecording = false
        applyStoredState()
        if let error = registrationError {
            action.persist(previous)
            applyStoredState()
            return error
        }
        Self.notifySettingsChanged()
        return nil
    }

    func restoreDefaultShortcuts() -> String? {
        let previous = ShortcutAction.allCases.map { ($0, $0.storedShortcut) }
        for action in ShortcutAction.allCases { action.persist(action.defaultShortcut) }
        isRecording = false
        applyStoredState()
        if let error = registrationError {
            for (action, shortcut) in previous { action.persist(shortcut) }
            applyStoredState()
            return error
        }
        Self.notifySettingsChanged()
        return nil
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

    private func installHandlerIfNeeded() -> Bool {
        guard eventHandler == nil else { return true }

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
            registrationError = "Could not install the shortcut handler (macOS error \(status))."
        }
        return status == noErr
    }

    private func registerHotKey(shortcut: KeyboardShortcut, action: ShortcutAction, id: UInt32) -> EventHotKeyRef? {
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr else {
            registrationError = "\(action.title): \(shortcut.displayName) could not be registered (macOS error \(status)). It may be in use by another app or macOS. Choose another shortcut or release it there."
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
        case Self.leftID: direction = .left
        case Self.rightID: direction = .right
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
