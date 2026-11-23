import CoreGraphics
import CStrafe
import XCTest
@testable import strafe

final class BoundaryTests: XCTestCase {
    func testOverlaySwipePassesThroughWithoutSwitching() {
        let engine = RecordingEngine()
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { true })
        for phase: Int64 in [1, 2, 4] {
            let sample = event(phase)
            let result = interceptor.handle(type: CGEventType(rawValue: 30)!, event: sample)
            XCTAssertTrue(result?.takeUnretainedValue() === sample)
            XCTAssertEqual(strafe_event_swipe_progress(sample), 0.1, accuracy: 1e-6)
        }
        XCTAssertEqual(engine.attempts, 0)
    }

    func testEngineBlocksBothEdges() {
        for (index, direction) in [(UInt32(0), SwitchDirection.left), (4, .right)] {
            let engine = GestureSwitchEngine(spaceInfo: {
                var info = StrafeInfo()
                info.currentIndex = index
                info.spaceCount = 5
                return info
            })
            for _ in 0..<3 {
                XCTAssertThrowsError(try engine.switchSpace(direction)) { error in
                    guard case SwitchEngineError.atEdge = error else {
                        return XCTFail("Expected atEdge, got \(error)")
                    }
                }
            }
        }
    }

    func testBlockedSwipeSuppressesEndAndNextSwipeStillWorks() {
        let engine = RecordingEngine()
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false })
        engine.atEdge = true
        XCTAssertNil(send(1, to: interceptor))
        XCTAssertNil(send(2, to: interceptor))
        XCTAssertNil(send(2, to: interceptor))
        XCTAssertNil(send(4, to: interceptor))
        XCTAssertEqual(engine.attempts, 1)

        engine.atEdge = false
        XCTAssertNil(send(1, to: interceptor))
        XCTAssertNil(send(2, to: interceptor))
        XCTAssertNil(send(2, to: interceptor))
        let end = event(4)
        let result = interceptor.handle(type: CGEventType(rawValue: 30)!, event: end)
        if strafe_uses_iohid_payload() {
            XCTAssertNotNil(result)
            XCTAssertEqual(strafe_event_swipe_progress(end), 0)
            XCTAssertEqual(strafe_event_swipe_velocity_x(end), 0)
        } else {
            XCTAssertNil(result)
        }
        XCTAssertEqual(engine.attempts, 2)
    }

    func testBlockedDiscreteSwipeSuppressesItsTerminalEvent() {
        let engine = RecordingEngine()
        engine.atEdge = true
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false })
        XCTAssertNil(send(1, to: interceptor))
        XCTAssertNil(send(4, to: interceptor))
        XCTAssertEqual(engine.attempts, 1)
    }

    func testHeldDragFollowsFingersAndCommitsOnlyOnReleaseAtHalfway() {
        let engine = RecordingEngine()
        let interceptor = SwipeInterceptor(
            engine: engine, dragToSwitch: true, spaceCount: { 3 }, isExposeActive: { false })

        for sign in [-1.0, 1.0] {
            // Three Spaces need 1.5 units of raw progress for one full slide.
            for (phase, distance) in [(1, 0.0), (2, 0.35), (2, 0.75), (2, 0.75), (4, 0.75)] {
                let sample = event(Int64(phase), progress: sign * distance)
                let originalProgress = strafe_event_swipe_progress(sample)
                let result = interceptor.handle(type: CGEventType(rawValue: 30)!, event: sample)
                XCTAssertTrue(result?.takeUnretainedValue() === sample)
                XCTAssertEqual(strafe_event_swipe_progress(sample), originalProgress)
                XCTAssertEqual(engine.attempts, 0, "Dock owns the drag and its release")
            }
        }
    }

    func testReversingBelowHalfwayCancelsEvenWithAReleaseFlick() throws {
        let engine = RecordingEngine()
        let interceptor = SwipeInterceptor(
            engine: engine, dragToSwitch: true, spaceCount: { 3 }, isExposeActive: { false })
        for (phase, progress) in [(1, 0.0), (2, 0.9), (2, 0.74)] {
            let sample = event(Int64(phase), progress: progress)
            XCTAssertTrue(interceptor.handle(type: CGEventType(rawValue: 30)!, event: sample)?
                .takeUnretainedValue() === sample)
        }
        let release = event(4, progress: 0.9)
        let result = try XCTUnwrap(interceptor.handle(type: CGEventType(rawValue: 30)!, event: release))
        guard result.takeUnretainedValue() !== release else {
            return XCTFail("Releasing below halfway must not forward the real flick")
        }
        let cancellation = result.takeRetainedValue()
        XCTAssertEqual(strafe_event_gesture_phase(cancellation), strafe_gesture_phase_cancelled())
        XCTAssertEqual(strafe_event_swipe_velocity_x(cancellation), 0)
        XCTAssertEqual(engine.attempts, 0)
    }

    private func event(_ phase: Int64, progress: Double = 0.1) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.setIntegerValueField(CGEventField(rawValue: 55)!, value: 30)
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        event.setDoubleValueField(CGEventField(rawValue: 124)!, value: progress)
        event.setDoubleValueField(CGEventField(rawValue: 129)!, value: 10)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }

    private func send(_ phase: Int64, to interceptor: SwipeInterceptor) -> Unmanaged<CGEvent>? {
        interceptor.handle(type: CGEventType(rawValue: 30)!, event: event(phase))
    }
}

private final class RecordingEngine: SwitchEngine {
    var atEdge = false
    var attempts = 0
    func switchSpace(_ direction: SwitchDirection) throws {
        attempts += 1
        if atEdge { throw SwitchEngineError.atEdge }
    }
}
