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

    func testHeldDragFollowsFingersAndFinishesOnlyOnReleaseAtHalfway() throws {
        let engine = RecordingEngine()
        let interceptor = dragInterceptor(engine)

        for (sign, direction) in [(-1.0, SwitchDirection.left), (1.0, .right)] {
            // Three Spaces need 1.5 units of raw progress for one full slide.
            for (phase, distance) in [(1, 0.0), (2, 0.35), (2, 0.75), (2, 0.75)] {
                let sample = event(Int64(phase), progress: sign * distance)
                let originalProgress = strafe_event_swipe_progress(sample)
                XCTAssertTrue(handle(sample, with: interceptor)?.takeUnretainedValue() === sample)
                XCTAssertEqual(strafe_event_swipe_progress(sample), originalProgress)
                XCTAssertTrue(engine.finishes.isEmpty, "A held drag cannot commit")
            }
            XCTAssertNil(handle(event(4, velocity: 0), with: interceptor))
            let finish = try XCTUnwrap(engine.finishes.popLast())
            XCTAssertEqual(finish.preview.progress, sign * 0.75)
            XCTAssertEqual(finish.destination, direction)
        }
        XCTAssertEqual(engine.attempts, 0, "Neither release starts a separate swipe")
    }

    func testReversingOrHoldingBelowHalfwayReturnsToTheOriginalSpace() throws {
        let engine = RecordingEngine()
        let interceptor = dragInterceptor(engine)
        for (positions, releasedAt) in [([0.9, 0.74], UInt64(30_000_000)), ([0.65, 0.65], 300_000_000)] {
            _ = handle(event(1, progress: 0, timestamp: 0), with: interceptor)
            for (index, progress) in positions.enumerated() {
                _ = handle(event(2, progress: progress, timestamp: UInt64(index + 1) * 10_000_000), with: interceptor)
            }
            XCTAssertNil(handle(event(4, progress: 0.9, velocity: 10, timestamp: releasedAt), with: interceptor))
            let finish = try XCTUnwrap(engine.finishes.popLast())
            XCTAssertEqual(finish.preview.progress, positions.last!, accuracy: 1e-6)
            XCTAssertNil(finish.destination)
        }
    }

    func testQuickFlickStillSwitchesInDragModeIncludingDuringAnotherFinish() throws {
        let engine = RecordingEngine()
        let interceptor = dragInterceptor(engine)
        for pending in [false, true] {
            engine.hasPendingRamp = pending
            let began = event(1, progress: 0, timestamp: 0)
            let changed = event(2, progress: -0.25, timestamp: 20_000_000)
            if pending {
                XCTAssertNil(handle(began, with: interceptor))
                XCTAssertNil(handle(changed, with: interceptor))
            } else {
                XCTAssertTrue(handle(began, with: interceptor)?.takeUnretainedValue() === began)
                XCTAssertTrue(handle(changed, with: interceptor)?.takeUnretainedValue() === changed)
            }
            XCTAssertNil(handle(event(4, velocity: -8, timestamp: 25_000_000), with: interceptor))
            if pending {
                XCTAssertEqual(engine.attempts, 1, "A second flick queues a full switch without another live preview")
                XCTAssertEqual(engine.lastDirection, .left)
                XCTAssertTrue(engine.finishes.isEmpty)
            } else {
                let finish = try XCTUnwrap(engine.finishes.popLast())
                XCTAssertEqual(finish.preview.progress, -0.25)
                XCTAssertEqual(finish.destination, .left)
            }
        }
    }

    private func dragInterceptor(_ engine: RecordingEngine) -> SwipeInterceptor {
        SwipeInterceptor(engine: engine, dragToSwitch: true, spaceCount: { 3 }, isExposeActive: { false })
    }

    private func handle(_ event: CGEvent, with interceptor: SwipeInterceptor) -> Unmanaged<CGEvent>? {
        interceptor.handle(type: CGEventType(rawValue: 30)!, event: event)
    }

    private func event(_ phase: Int64, progress: Double = 0.1, velocity: Double = 10,
                       timestamp: CGEventTimestamp = 0) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.setIntegerValueField(CGEventField(rawValue: 55)!, value: 30)
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        event.setDoubleValueField(CGEventField(rawValue: 124)!, value: progress)
        event.setDoubleValueField(CGEventField(rawValue: 129)!, value: velocity)
        event.timestamp = timestamp
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }

    private func send(_ phase: Int64, to interceptor: SwipeInterceptor) -> Unmanaged<CGEvent>? {
        interceptor.handle(type: CGEventType(rawValue: 30)!, event: event(phase))
    }
}

private final class RecordingEngine: DragSwitchEngine {
    var atEdge = false
    var attempts = 0
    var lastDirection: SwitchDirection?
    var hasPendingRamp = false
    var finishes: [(preview: DragContinuation, destination: SwitchDirection?)] = []

    func finishDrag(_ drag: DragContinuation, toward direction: SwitchDirection?) {
        finishes.append((drag, direction))
    }

    func switchSpace(_ direction: SwitchDirection) throws {
        attempts += 1
        lastDirection = direction
        if atEdge { throw SwitchEngineError.atEdge }
    }
}
