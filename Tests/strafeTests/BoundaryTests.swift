import CoreGraphics
import CStrafe
import XCTest
@testable import strafe

final class BoundaryTests: XCTestCase {
    func testOverlaySwipePassesThroughWithoutSwitching() {
        let engine = RecordingEngine()
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { true }, releaseSpeed: { nil })
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
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false }, releaseSpeed: { nil })
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
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false }, releaseSpeed: { nil })
        XCTAssertNil(send(1, to: interceptor))
        XCTAssertNil(send(4, to: interceptor))
        XCTAssertEqual(engine.attempts, 1)
    }

    private func event(_ phase: Int64) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.setIntegerValueField(CGEventField(rawValue: 55)!, value: 30)
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        event.setDoubleValueField(CGEventField(rawValue: 124)!, value: 0.1)
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
