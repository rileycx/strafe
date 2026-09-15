import Foundation
import CoreGraphics
import CStrafe

// Standalone runner: works with Command Line Tools without XCTest/Xcode.
// Compile alongside SwitchEngine.swift and SwitchDiagnostics.swift.
@main
struct SwitchEngineTests {
    final class CompletionWaiter: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        func fulfill() { semaphore.signal() }
        func wait() { precondition(semaphore.wait(timeout: .now() + 3) == .success, "Completion timed out") }
    }

    static func main() throws {
        let tests = SwitchEngineTests()
        try tests.testConfigurationDefaultsAndInvalidValues()
        try tests.testIgnoredPostsTimeoutDropQueueAndRecoverFromRealIndex()
        try tests.testSequencesArePacedOrderedAndObserveOriginalDisplay()
        try tests.testWrongDirectionIsNotReportedAsSuccess()
        try tests.testBuilderFailureNeverPostsPartialGesture()
        try tests.testTrueEdgeDoesNotPost()
        try tests.testMacOS27DirectionAndBothEdges()
        try tests.testOverlayBlocksAndCancelsPendingGesture()
        try tests.testPhysicalGestureMappingAndPassthrough()
        SwitchDiagnostics.flush()
        print("Swift: 9 configuration/engine/interceptor tests passed (mock delivery; no events posted).")
    }
    private final class Desktop: @unchecked Sendable {
        let lock = NSLock()
        var index: UInt32 = 1
        var moves = false
        var reverse = false
        var overlay = false
        var openOverlayOnBegin = false
        var phases: [Int64] = []
        var times: [TimeInterval] = []
        var readDisplays: [String?] = []

        func read(_ display: String?) -> GestureSwitchEngine.Topology {
            lock.lock()
            defer { lock.unlock() }
            readDisplays.append(display)
            return .init(display: "display-A", index: index, count: 4, id: UInt64(index) + 10)
        }

        func post(_ event: CGEvent) {
            lock.lock()
            defer { lock.unlock() }
            let phase = strafe_event_gesture_phase(event)
            phases.append(phase)
            times.append(ProcessInfo.processInfo.systemUptime)
            if openOverlayOnBegin && phase == 1 { overlay = true }
            if moves && phase == 4 {
                let right = (strafe_event_swipe_progress(event) > 0) != reverse
                index = right ? index + 1 : index - 1
            }
        }

        func enableMoves() {
            lock.lock()
            moves = true
            lock.unlock()
        }

        func snapshot() -> (UInt32, [Int64], [TimeInterval], [String?]) {
            lock.lock()
            defer { lock.unlock() }
            return (index, phases, times, readDisplays)
        }

        var dependencies: GestureSwitchEngine.Dependencies {
            .init(read: { self.read($0) }, post: { self.post($0) }, overlayActive: {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.overlay
            })
        }
    }

    private func config(gap: String = "0") throws -> SwitchConfiguration {
        try .load(environment: ["STRAFE_EVENT_PROFILE": "legacy", "STRAFE_PHASE_GAP_MS": gap], osMajorVersion: 27)
    }

    func testConfigurationDefaultsAndInvalidValues() throws {
        let modern = try SwitchConfiguration.load(environment: [:], osMajorVersion: 27)
        precondition(modern.augmented && modern.phaseGapMS == 10 && modern.inverted)
        precondition(!modern.invertSwipeDirection)
        let flipped = try SwitchConfiguration.load(
            environment: ["STRAFE_INVERT_SWIPE_DIRECTION": "1"], osMajorVersion: 27)
        precondition(flipped.invertSwipeDirection)
        let legacy = try SwitchConfiguration.load(environment: [:], osMajorVersion: 26)
        let forced = try config()
        precondition(!legacy.augmented && !forced.augmented)
        for (key, value) in [("STRAFE_EVENT_PROFILE", "bad"), ("STRAFE_PHASE_GAP_MS", "nan"),
                             ("STRAFE_PHASE_GAP_MS", "-1"), ("STRAFE_PHASE_GAP_MS", "101"),
                             ("STRAFE_INVERT_DIRECTION", "yes"), ("STRAFE_DIAGNOSTICS", "true"),
                             ("STRAFE_INVERT_SWIPE_DIRECTION", "yes"), ("STRAFE_INTERCEPT_SWIPES", "yes")] {
            do {
                _ = try SwitchConfiguration.load(environment: [key: value])
                fatalError("Invalid configuration accepted: \(key)=\(value)")
            } catch is SwitchConfiguration.Invalid { }
        }
    }

    func testIgnoredPostsTimeoutDropQueueAndRecoverFromRealIndex() throws {
        let desktop = Desktop()
        let engine = GestureSwitchEngine(configuration: try config(), dependencies: desktop.dependencies)
        let failed = CompletionWaiter()
        let dropped = CompletionWaiter()
        let fallback = CompletionWaiter()
        engine.setDeliveryFailureHandler { error in
            guard case .observationTimedOut = error else { fatalError("Unexpected fallback: \(error)") }
            fallback.fulfill()
        }
        try engine.switchSpace(.left) { result in
            guard case .failure(.observationTimedOut) = result else { fatalError("Expected timeout: \(result)") }
            failed.fulfill()
        }
        try engine.switchSpace(.right) { result in
            guard case .failure(.pendingDropped) = result else { fatalError("Expected pending drop: \(result)") }
            dropped.fulfill()
        }
        failed.wait()
        dropped.wait()
        fallback.wait()
        precondition(desktop.snapshot().0 == 1)
        precondition(desktop.snapshot().1 == [1, 2, 4])
        desktop.enableMoves()
        let recovered = CompletionWaiter()
        try engine.switchSpace(.left) { result in
            guard case .success = result else { fatalError("Expected recovery: \(result)") }
            recovered.fulfill()
        }
        recovered.wait()
        precondition(desktop.snapshot().0 == 0)
    }

    func testSequencesArePacedOrderedAndObserveOriginalDisplay() throws {
        let desktop = Desktop()
        desktop.enableMoves()
        let engine = GestureSwitchEngine(configuration: try config(gap: "10"), dependencies: desktop.dependencies)
        let finished = CompletionWaiter()
        for direction in [SwitchDirection.right, .left] {
            try engine.switchSpace(direction) { result in
                guard case .success = result else { fatalError("Expected success: \(result)") }
                finished.fulfill()
            }
        }
        engine.resetPredictions() // Workspace notifications must not cancel work.
        finished.wait()
        finished.wait()
        let (index, phases, times, displays) = desktop.snapshot()
        precondition(index == 1)
        precondition(phases == [1, 2, 4, 1, 2, 4])
        for i in [1, 2, 4, 5] { precondition(times[i] - times[i - 1] >= 0.009) }
        precondition(displays.contains { $0 == "display-A" })
        precondition(displays.allSatisfy { $0 == nil || $0 == "display-A" })
    }

    func testWrongDirectionIsNotReportedAsSuccess() throws {
        let desktop = Desktop()
        desktop.reverse = true
        desktop.enableMoves()
        let engine = GestureSwitchEngine(configuration: try config(), dependencies: desktop.dependencies)
        let finished = CompletionWaiter()
        try engine.switchSpace(.right) { result in
            guard case .failure(.unexpectedChange) = result else { fatalError("Expected mismatch: \(result)") }
            finished.fulfill()
        }
        finished.wait()
    }

    func testBuilderFailureNeverPostsPartialGesture() throws {
        let desktop = Desktop()
        var dependencies = desktop.dependencies
        dependencies.build = { direction, velocity, phase, augmented, inverted in
            guard phase != 4 else { return nil }
            return strafe_create_switch_event(direction.cDirection, velocity, phase, augmented, inverted)
        }
        let engine = GestureSwitchEngine(configuration: try config(), dependencies: dependencies)
        let finished = CompletionWaiter()
        try engine.switchSpace(.right) { result in
            guard case .failure(.postFailed) = result else { fatalError("Expected construction failure: \(result)") }
            finished.fulfill()
        }
        finished.wait()
        precondition(desktop.snapshot().1.isEmpty)
    }

    func testTrueEdgeDoesNotPost() throws {
        let desktop = Desktop()
        desktop.index = 0
        let engine = GestureSwitchEngine(configuration: try config(), dependencies: desktop.dependencies)
        let finished = CompletionWaiter()
        try engine.switchSpace(.left) { result in
            guard case .failure(.atEdge) = result else { fatalError("Expected edge: \(result)") }
            finished.fulfill()
        }
        finished.wait()
        precondition(desktop.snapshot().1.isEmpty)
    }

    func testMacOS27DirectionAndBothEdges() throws {
        let desktop = Desktop()
        desktop.reverse = true // Observed OS27 behavior: negative output moves right.
        desktop.enableMoves()
        let config = try SwitchConfiguration.load(environment: [:], osMajorVersion: 27)
        let engine = GestureSwitchEngine(configuration: config, dependencies: desktop.dependencies)
        // Reproduce walking to both boundaries and then returning inward.
        for (direction, expectedIndex) in [(SwitchDirection.left, UInt32(0)), (.right, 1),
                                           (.right, 2), (.right, 3), (.left, 2)] {
            let finished = CompletionWaiter()
            try engine.switchSpace(direction) { result in
                guard case .success = result else { fatalError("OS27 direction failed: \(result)") }
                finished.fulfill()
            }
            finished.wait()
            precondition(desktop.snapshot().0 == expectedIndex)
        }
    }

    func testOverlayBlocksAndCancelsPendingGesture() throws {
        for alreadyOpen in [true, false] {
            let desktop = Desktop()
            desktop.overlay = alreadyOpen
            desktop.openOverlayOnBegin = !alreadyOpen
            let engine = GestureSwitchEngine(configuration: try config(gap: "10"), dependencies: desktop.dependencies)
            let finished = CompletionWaiter()
            try engine.switchSpace(.right) { result in
                guard case .failure(.overlayActive) = result else { fatalError("Overlay not respected: \(result)") }
                finished.fulfill()
            }
            finished.wait()
            precondition(desktop.snapshot().1 == (alreadyOpen ? [] : [1, 8]))
        }
    }

    private final class GestureSink: SwitchEngine {
        var directions: [SwitchDirection] = []
        func switchSpace(_ direction: SwitchDirection) throws { directions.append(direction) }
    }

    func testPhysicalGestureMappingAndPassthrough() throws {
        let sink = GestureSink()
        let config = try SwitchConfiguration.load(environment: [:], osMajorVersion: 27)
        let interceptor = SwipeInterceptor(engine: sink, configuration: config,
                                           overlayActive: { false }, overlaySnapshot: { false })
        func event(_ phase: Int64, right: Bool = false, generic: Bool = false, vertical: Bool = false) -> CGEvent {
            // A separate source avoids inheriting the builder's source marker.
            let result = CGEvent(source: CGEventSource(stateID: .privateState))!
            result.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            result.setIntegerValueField(CGEventField(rawValue: 55)!, value: 30)
            result.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
            result.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
            result.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
            result.setDoubleValueField(CGEventField(rawValue: 124)!, value: right ? 0.1 : -0.1)
            result.setDoubleValueField(CGEventField(rawValue: 129)!, value: right ? 1 : -1)
            if generic {
                result.setIntegerValueField(CGEventField(rawValue: 55)!, value: 29)
                result.setIntegerValueField(CGEventField(rawValue: 110)!, value: 32)
                result.setDoubleValueField(CGEventField(rawValue: 119)!, value: 0.25)
            }
            if vertical { result.setIntegerValueField(CGEventField(rawValue: 123)!, value: 2) }
            return result
        }
        // Upstream convention (now the default): negative physical progress
        // means the previous (left) workspace, positive means right.
        for phase: Int64 in [1, 1, 2, 2, 4] {
            let sample = event(phase)
            precondition(interceptor.handle(type: CGEventType(rawValue: 30)!, event: sample) == nil,
                         "phase=\(phase) pid=\(strafe_event_source_pid(sample)) marker=\(strafe_event_is_strafe(sample)) type=\(strafe_event_cgs_type(sample)) hid=\(strafe_event_hid_type(sample)) axis=\(strafe_event_swipe_motion(sample))")
        }
        precondition(sink.directions == [.left])
        for phase: Int64 in [1, 2, 4] {
            precondition(interceptor.handle(type: CGEventType(rawValue: 30)!, event: event(phase, right: true)) == nil)
        }
        precondition(sink.directions == [.left, .right])
        // Generic HID32 and vertical Dock gestures remain native, even while
        // Strafe owns a horizontal swipe. They must not drive or clear its latch.
        _ = interceptor.handle(type: CGEventType(rawValue: 30)!, event: event(1))
        for phase: Int64 in [1, 2, 4] {
            precondition(interceptor.handle(type: CGEventType(rawValue: 29)!, event: event(phase, generic: true)) != nil)
            precondition(interceptor.handle(type: CGEventType(rawValue: 30)!, event: event(phase, vertical: true)) != nil)
        }
        _ = interceptor.handle(type: CGEventType(rawValue: 30)!, event: event(2))
        _ = interceptor.handle(type: CGEventType(rawValue: 30)!, event: event(4))
        precondition(sink.directions == [.left, .right, .left])
        let overlay = SwipeInterceptor(engine: sink, configuration: config,
                                       overlayActive: { true }, overlaySnapshot: { false })
        for phase: Int64 in [1, 2, 4] {
            precondition(overlay.handle(type: CGEventType(rawValue: 30)!, event: event(phase)) != nil)
        }
        precondition(sink.directions.count == 3)
    }
}
