import AppKit
import Carbon.HIToolbox

// Compile the production manager with an isolated preferences domain and
// replacement Carbon registration functions. No real shortcuts are captured.
enum Preferences {
    static let domain = CommandLine.arguments[1]
    nonisolated(unsafe) static let store = UserDefaults(suiteName: domain)!
}
enum SwitchDirection { case left, right }
protocol SwitchEngine { func switchSpace(_ direction: SwitchDirection) throws }
struct TestEngine: SwitchEngine {
    func switchSpace(_ direction: SwitchDirection) throws {
        preconditionFailure("No keyboard events should be delivered during these tests")
    }
}
@_silgen_name("test_active_hotkeys") private func activeHotkeys() -> UInt32
@_silgen_name("test_registration_count") private func registrationCount() -> UInt32
@_silgen_name("test_reject_key") private func rejectKey(_ key: UInt32)

@main struct HotkeyManagerTests {
    @MainActor static func main() {
        let mode = CommandLine.arguments[2]
        if mode == "on" || mode == "off" {
            HotkeyManager.persist(enabled: mode == "on")
            return
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let manager = HotkeyManager(engine: TestEngine())
        manager.start()
        defer { manager.stop() }
        if mode == "selftest" {
            precondition(HotkeyManager.enabled && activeHotkeys() == 2)
            manager.start()
            manager.applyStoredState()
            manager.applyStoredState()
            precondition(activeHotkeys() == 2 && registrationCount() == 2)
            HotkeyManager.persist(enabled: false)
            manager.applyStoredState()
            precondition(activeHotkeys() == 0)
            manager.applyStoredState()
            precondition(activeHotkeys() == 0)
            HotkeyManager.persist(enabled: true)
            manager.applyStoredState()
            precondition(activeHotkeys() == 2 && registrationCount() == 4)
            manager.stop()
            precondition(activeHotkeys() == 0)
            manager.start()
            precondition(activeHotkeys() == 2)
            let custom = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(cmdKey | shiftKey))
            precondition(manager.updateShortcut(custom, for: .left) == nil)
            precondition(ShortcutAction.left.storedShortcut == custom && activeHotkeys() == 2)
            precondition(manager.updateShortcut(custom, for: .right) != nil)
            precondition(ShortcutAction.right.storedShortcut == ShortcutAction.right.defaultShortcut)
            precondition(manager.updateShortcut(KeyboardShortcut(keyCode: 0, modifiers: 0), for: .left) != nil)
            precondition(manager.updateShortcut(KeyboardShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(cmdKey)), for: .left) != nil)
            precondition(custom.displayName.hasPrefix("⇧⌘"))
            manager.setRecording(true)
            precondition(activeHotkeys() == 0)
            manager.setRecording(false)
            precondition(activeHotkeys() == 2)
            rejectKey(UInt32(kVK_ANSI_K))
            let conflicting = KeyboardShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey))
            precondition(manager.updateShortcut(conflicting, for: .left) != nil)
            precondition(ShortcutAction.left.storedShortcut == custom && activeHotkeys() == 2)
            precondition(manager.registrationError == nil)
            rejectKey(UInt32.max)
            precondition(manager.updateShortcut(nil, for: .right) == nil)
            precondition(ShortcutAction.right.storedShortcut == nil && activeHotkeys() == 1)
            manager.stop()
            manager.start()
            precondition(activeHotkeys() == 1 && ShortcutAction.left.storedShortcut == custom)
            precondition(manager.restoreDefaultShortcuts() == nil && activeHotkeys() == 2)
            precondition(ShortcutAction.left.storedShortcut == ShortcutAction.left.defaultShortcut)
            print("PASS: default, repeated enable/disable, and restart")
            print("PASS: customization, persistence, duplicate/reserved validation, recorder suspension, conflict rollback, clear, restore")
            return
        }
        precondition(mode == "listen")
        var previous = activeHotkeys()
        print("ACTIVE \(previous)"); fflush(stdout)
        let deadline = Date(timeIntervalSinceNow: 12)
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in }
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            let current = activeHotkeys()
            if current != previous {
                print("ACTIVE \(current)"); fflush(stdout)
                previous = current
            }
        }
    }
}
