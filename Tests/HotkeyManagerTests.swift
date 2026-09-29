import AppKit
import Carbon.HIToolbox

// Compile the production manager with an isolated preferences domain and
// replacement Carbon registration functions. No real shortcuts are captured.
enum Preferences {
    static let domain = CommandLine.arguments[1]
    nonisolated(unsafe) static let store = UserDefaults(suiteName: domain)!
}
enum SwitchDirection: Equatable { case left, right }
protocol SwitchEngine { func switchSpace(_ direction: SwitchDirection) throws }
final class TestEngine: SwitchEngine {
    var directions: [SwitchDirection] = []
    func switchSpace(_ direction: SwitchDirection) throws {
        directions.append(direction)
    }
}
@_silgen_name("test_active_hotkeys") private func activeHotkeys() -> UInt32
@_silgen_name("test_registration_count") private func registrationCount() -> UInt32

@_silgen_name("test_fail_registration") private func failRegistration(_ id: UInt32)
@_silgen_name("test_fire_hotkey") private func fireHotkey(_ id: UInt32, _ signature: UInt32) -> Int32

@main struct HotkeyManagerTests {
    @MainActor static func main() {
        let mode = CommandLine.arguments[2]
        if mode == "on" || mode == "off" {
            HotkeyManager.persist(enabled: mode == "on")
            return
        }
        if mode == "control-on" || mode == "control-off" {
            HotkeyManager.persist(controlArrowsEnabled: mode == "control-on")
            return
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let engine = TestEngine()
        let manager = HotkeyManager(engine: engine)
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
            precondition(!HotkeyManager.controlArrowsEnabled && !manager.controlArrowsRegistered)
            HotkeyManager.persist(controlArrowsEnabled: true)
            manager.applyStoredState()
            precondition(activeHotkeys() == 4 && manager.controlArrowsRegistered)
            let count = registrationCount()
            manager.applyStoredState()
            manager.start()
            precondition(activeHotkeys() == 4 && registrationCount() == count)
            for id: UInt32 in 1...4 { precondition(fireHotkey(id, 0x534E4150) == noErr) }
            precondition(engine.directions == [.left, .right, .left, .right])
            precondition(fireHotkey(1, 0xBAD) == eventNotHandledErr)
            _ = fireHotkey(99, 0x534E4150)
            precondition(engine.directions.count == 4)
            HotkeyManager.persist(enabled: false)
            manager.applyStoredState()
            precondition(activeHotkeys() == 0 && !manager.controlArrowsRegistered)
            HotkeyManager.persist(enabled: true)
            manager.applyStoredState()
            precondition(activeHotkeys() == 4)
            manager.stop()
            precondition(activeHotkeys() == 0)
            manager.start()
            precondition(activeHotkeys() == 4)
            for failedID: UInt32 in [3, 4] {
                HotkeyManager.persist(controlArrowsEnabled: false)
                manager.applyStoredState()
                precondition(activeHotkeys() == 2)
                failRegistration(failedID)
                HotkeyManager.persist(controlArrowsEnabled: true)
                manager.applyStoredState()
                precondition(activeHotkeys() == 2 && !manager.controlArrowsRegistered)
                failRegistration(0)
                manager.applyStoredState()
                precondition(activeHotkeys() == 4 && manager.controlArrowsRegistered)
            }
            HotkeyManager.persist(controlArrowsEnabled: false)
            manager.applyStoredState()
            precondition(activeHotkeys() == 2 && !manager.controlArrowsRegistered)
            print("PASS: defaults, opt-in, routing, repeat, restart, rollback, and retry")
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
