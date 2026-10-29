import CoreGraphics
import XCTest
@testable import strafe

final class ControlArrowTests: XCTestCase {
    private final class Engine: SwitchEngine {
        var directions: [SwitchDirection] = []
        var error: SwitchEngineError?
        func switchSpace(_ direction: SwitchDirection) throws {
            if let error { throw error }
            directions.append(direction)
        }
    }

    private final class Shortcuts: NativeSpaceShortcuts {
        var events: [String] = []
        var canSuspend = true
        func suspend() -> Bool {
            guard canSuspend else { return false }
            events.append("suspend")
            return true
        }
        func resume() { events.append("resume") }
        func recoverIfNeeded() { events.append("recover") }
    }

    private func make(engine: Engine = Engine(), shortcuts: Shortcuts = Shortcuts(),
                      canSwitch: Bool = true, expose: Bool = false,
                      flags: CGEventFlags = []) -> ControlArrowInterceptor {
        ControlArrowInterceptor(engine: engine, shortcuts: shortcuts,
                                canSwitch: { canSwitch }, isExposeActive: { expose },
                                currentFlags: { flags })
    }

    func testControlDownPausesNativeOnceAndControlUpResumes() {
        let shortcuts = Shortcuts()
        let tap = make(shortcuts: shortcuts)
        tap.handleModifiers(.maskControl)
        tap.handleModifiers([.maskControl, .maskShift]) // still held: no second call
        XCTAssertEqual(shortcuts.events, ["suspend"])
        tap.handleModifiers([])
        tap.handleModifiers([]) // already back: no second call
        XCTAssertEqual(shortcuts.events, ["suspend", "resume"])
    }

    func testOtherModifiersNeverPauseNative() {
        let shortcuts = Shortcuts()
        let tap = make(shortcuts: shortcuts)
        for flags: CGEventFlags in [.maskShift, .maskCommand, .maskAlternate,
                                   .maskAlphaShift, .maskSecondaryFn, []] {
            tap.handleModifiers(flags)
        }
        XCTAssertTrue(shortcuts.events.isEmpty)
    }

    func testMissionControlKeepsNativeArrowHandling() {
        let shortcuts = Shortcuts()
        let tap = make(shortcuts: shortcuts, expose: true)
        tap.handleModifiers(.maskControl)
        XCTAssertTrue(shortcuts.events.isEmpty)
    }

    func testUnavailablePrivateCallLeavesNativeAlone() {
        let shortcuts = Shortcuts()
        shortcuts.canSuspend = false
        let tap = make(shortcuts: shortcuts)
        tap.handleModifiers(.maskControl)
        tap.handleModifiers([]) // nothing was paused, so nothing to resume
        XCTAssertTrue(shortcuts.events.isEmpty)
    }

    func testHotKeySwitchesBothDirections() {
        let engine = Engine()
        let tap = make(engine: engine)
        tap.handleHotKey(.left)
        tap.handleHotKey(.right)
        XCTAssertTrue(engine.directions == [.left, .right])
    }

    func testHotKeyIgnoredWithoutPermissionOrDuringMissionControl() {
        for (permission, overlay) in [(false, false), (true, true)] {
            let engine = Engine()
            make(engine: engine, canSwitch: permission, expose: overlay).handleHotKey(.left)
            XCTAssertTrue(engine.directions.isEmpty)
        }
    }

    func testEdgeAndEngineFailuresDoNotCrash() {
        let engine = Engine()
        let tap = make(engine: engine)
        engine.error = .atEdge
        tap.handleHotKey(.left)
        engine.error = .postFailed
        tap.handleHotKey(.right)
        XCTAssertTrue(engine.directions.isEmpty)
    }

    func testTapTimeoutResumesNativeThenResyncsFromRealModifiers() {
        for type: CGEventType in [.tapDisabledByTimeout, .tapDisabledByUserInput] {
            // Control still down after the disable: pause again.
            var shortcuts = Shortcuts()
            var tap = make(shortcuts: shortcuts, flags: .maskControl)
            tap.handleModifiers(.maskControl)
            tap.handleTap(type: type, flags: [])
            XCTAssertEqual(shortcuts.events, ["suspend", "resume", "suspend"])

            // Control released while the tap was off: stay on native.
            shortcuts = Shortcuts()
            tap = make(shortcuts: shortcuts, flags: [])
            tap.handleModifiers(.maskControl)
            tap.handleTap(type: type, flags: [])
            XCTAssertEqual(shortcuts.events, ["suspend", "resume"])
        }
    }

    func testStopGivesNativeShortcutsBack() {
        let shortcuts = Shortcuts()
        let tap = make(shortcuts: shortcuts)
        tap.handleModifiers(.maskControl)
        tap.stop()
        XCTAssertEqual(shortcuts.events, ["suspend", "resume"])
        XCTAssertFalse(tap.isRunning)
        tap.stop() // idempotent
        XCTAssertEqual(shortcuts.events, ["suspend", "resume"])
    }
}
