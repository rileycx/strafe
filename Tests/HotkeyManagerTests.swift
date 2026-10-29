import AppKit

// Compile the production manager with an isolated preferences domain and
// a fake interceptor. No real keyboard events are captured.
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

// Isolate settings lifecycle from the real keyboard tap.
final class ControlArrowInterceptor {
    private(set) var isRunning = false
    init(engine: SwitchEngine) {}
    func start() { isRunning = true }
    func stop() { isRunning = false }
}

@main struct HotkeyManagerTests {
    @MainActor static func main() {
        let mode = CommandLine.arguments[2]
        if mode == "on" || mode == "off" {
            HotkeyManager.persist(controlArrowsEnabled: mode == "on")
            return
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let manager = HotkeyManager(engine: TestEngine())
        manager.start()
        defer { manager.stop() }
        if mode == "selftest" {
            precondition(Preferences.store.object(forKey: HotkeyManager.controlArrowsStorageKey) == nil)
            precondition(HotkeyManager.controlArrowsEnabled && manager.controlArrowsRunning)
            manager.start()
            manager.applyStoredState()
            precondition(manager.controlArrowsRunning)
            HotkeyManager.persist(controlArrowsEnabled: true)
            manager.applyStoredState()
            manager.applyStoredState()
            precondition(manager.controlArrowsRunning)
            manager.stop()
            precondition(!manager.controlArrowsRunning)
            manager.start()
            precondition(manager.controlArrowsRunning)
            HotkeyManager.persist(controlArrowsEnabled: false)
            manager.applyStoredState()
            manager.applyStoredState()
            precondition(!manager.controlArrowsRunning)
            manager.stop()
            manager.start()
            precondition(!HotkeyManager.controlArrowsEnabled && !manager.controlArrowsRunning)
            print("PASS: default on, saved off survives restart, repeated application, stop, restart")
            return
        }
        precondition(mode == "listen")
        var previous = (manager.controlArrowsRunning ? 1 : 0)
        print("ACTIVE \(previous)"); fflush(stdout)
        let deadline = Date(timeIntervalSinceNow: 12)
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in }
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            let current = (manager.controlArrowsRunning ? 1 : 0)
            if current != previous {
                print("ACTIVE \(current)"); fflush(stdout)
                previous = current
            }
        }
    }
}
