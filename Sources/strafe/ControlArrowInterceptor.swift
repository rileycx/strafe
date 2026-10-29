import Carbon.HIToolbox
import CoreGraphics
import Foundation
import CStrafe

/// Turns the native "Move left/right a space" shortcuts off in memory while
/// Control is held, so a Carbon hotkey on Control+Left/Right can win and use
/// strafe's instant switch. Native handling is back the moment Control is
/// released. Main-run-loop confined, like SwipeInterceptor.
///
/// The only keyboard input this ever receives is modifier changes: its event
/// tap masks `flagsChanged` and nothing else, so letters, numbers and other
/// keys are never delivered. The Carbon hotkeys fire only for the exact combo.
final class ControlArrowInterceptor: @unchecked Sendable {
    private let engine: SwitchEngine
    private let shortcuts: NativeSpaceShortcuts
    private let canSwitch: () -> Bool
    private let isExposeActive: () -> Bool
    private let currentFlags: () -> CGEventFlags
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotKeyHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var suspended = false

    var isRunning: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    init(engine: SwitchEngine,
         shortcuts: NativeSpaceShortcuts = SystemSpaceShortcuts(),
         canSwitch: @escaping () -> Bool = { Permissions.isAccessibilityGranted },
         isExposeActive: @escaping () -> Bool = { strafe_is_expose_active() },
         currentFlags: @escaping () -> CGEventFlags = {
             CGEventSource.flagsState(.combinedSessionState)
         }) {
        self.engine = engine
        self.shortcuts = shortcuts
        self.canSwitch = canSwitch
        self.isExposeActive = isExposeActive
        self.currentFlags = currentFlags
    }

    func start() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            return
        }
        // A previous run that died while Control was held leaves the native
        // shortcuts off; put them back before anything else.
        shortcuts.recoverIfNeeded()
        guard registerHotKeys() else { return }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventType.flagsChanged.rawValue,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                Unmanaged<ControlArrowInterceptor>.fromOpaque(context)
                    .takeUnretainedValue().handleTap(type: type, flags: event.flags)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            FileHandle.standardError.write(Data(
                "[ControlArrowInterceptor] Cannot create modifier tap; native shortcuts remain available. Check Accessibility.\n".utf8))
            unregisterHotKeys()
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            unregisterHotKeys()
            return
        }
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // Control may already be down when the option is switched on.
        handleModifiers(currentFlags())
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
        unregisterHotKeys()
        resume()
    }

    // MARK: - Modifier tracking

    func handleTap(type: CGEventType, flags: CGEventFlags) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Flag changes may have been missed; go back to native, re-arm,
            // then resync from the real modifier state.
            resume()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            handleModifiers(currentFlags())
            return
        }
        guard type == .flagsChanged else { return }
        handleModifiers(flags)
    }

    func handleModifiers(_ flags: CGEventFlags) {
        if flags.contains(.maskControl) {
            // Leave Mission Control's own arrow handling alone.
            guard !suspended, !isExposeActive() else { return }
            suspended = shortcuts.suspend()
        } else {
            resume()
        }
    }

    private func resume() {
        guard suspended else { return }
        suspended = false
        shortcuts.resume()
    }

    // MARK: - Hotkeys

    func handleHotKey(_ direction: SwitchDirection) {
        // Native handling is off while Control is held, so there is nothing
        // to pass through: an unavailable switch is simply a no-op.
        guard canSwitch(), !isExposeActive() else { return }
        do {
            try engine.switchSpace(direction)
        } catch SwitchEngineError.atEdge {
            return // Same as native: nothing beyond the last Space.
        } catch {
            FileHandle.standardError.write(
                Data("[ControlArrowInterceptor] switchSpace failed: \(error)\n".utf8))
        }
    }

    private func registerHotKeys() -> Bool {
        guard hotKeys.isEmpty else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userInfo -> OSStatus in
                guard let userInfo, let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr else { return status }
                let direction: SwitchDirection
                switch id.id {
                case ControlArrowInterceptor.leftID: direction = .left
                case ControlArrowInterceptor.rightID: direction = .right
                default: return OSStatus(eventNotHandledErr)
                }
                Unmanaged<ControlArrowInterceptor>.fromOpaque(userInfo)
                    .takeUnretainedValue().handleHotKey(direction)
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        guard status == noErr else { return false }
        for (id, key) in [(Self.leftID, kVK_LeftArrow), (Self.rightID, kVK_RightArrow)] {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(
                UInt32(key), UInt32(controlKey),
                EventHotKeyID(signature: Self.signature, id: id),
                GetApplicationEventTarget(), 0, &ref)
            guard result == noErr, let ref else {
                FileHandle.standardError.write(Data(
                    "[ControlArrowInterceptor] RegisterEventHotKey failed (status \(result)); native shortcuts remain available.\n".utf8))
                unregisterHotKeys()
                return false
            }
            hotKeys.append(ref)
        }
        return true
    }

    private func unregisterHotKeys() {
        for ref in hotKeys { UnregisterEventHotKey(ref) }
        hotKeys = []
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        hotKeyHandler = nil
    }

    private static let signature: OSType = 0x53_54_52_46 // 'STRF'
    private static let leftID: UInt32 = 1
    private static let rightID: UInt32 = 2
}

/// Switches the native Control+Left/Right Space shortcuts off and on. Live
/// WindowServer state only; System Settings and its preference file are never
/// edited, so nothing needs restoring in Settings.
protocol NativeSpaceShortcuts {
    /// Turn the native shortcuts off. False if that is not possible.
    func suspend() -> Bool
    func resume()
    /// Re-enable after a run that ended while they were off.
    func recoverIfNeeded()
}

struct SystemSpaceShortcuts: NativeSpaceShortcuts {
    /// Set while the shortcuts are off, so a crash while Control was held is
    /// healed the next time strafe starts. Cleared as soon as they are back.
    static let suspendedStorageKey = "nativeSpaceShortcutsSuspended"

    func suspend() -> Bool {
        Preferences.store.set(true, forKey: Self.suspendedStorageKey)
        guard strafe_set_space_arrow_shortcuts_enabled(false) else {
            // Do not leave them half-off if only one call went through.
            _ = strafe_set_space_arrow_shortcuts_enabled(true)
            Preferences.store.set(false, forKey: Self.suspendedStorageKey)
            return false
        }
        return true
    }

    func resume() {
        _ = strafe_set_space_arrow_shortcuts_enabled(true)
        Preferences.store.set(false, forKey: Self.suspendedStorageKey)
    }

    func recoverIfNeeded() {
        if Preferences.store.bool(forKey: Self.suspendedStorageKey) { resume() }
    }
}
