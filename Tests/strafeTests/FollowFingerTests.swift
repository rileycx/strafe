import CoreGraphics
import CStrafe
import XCTest
@testable import strafe

final class FollowFingerTests: XCTestCase {
    func testSettleDirection() {
        // Slow release: past halfway switches, otherwise snaps back.
        XCTAssertEqual(FollowFinger.settleDirection(progress: 0.7, velocity: 0), 1)
        XCTAssertEqual(FollowFinger.settleDirection(progress: 0.3, velocity: 0), -1)
        XCTAssertEqual(FollowFinger.settleDirection(progress: -0.6, velocity: 0), -1)
        // Flick: settles the way it was moving, however far it got.
        XCTAssertEqual(FollowFinger.settleDirection(progress: 0.2, velocity: 3), 1)
        XCTAssertEqual(FollowFinger.settleDirection(progress: 0.8, velocity: -3), -1)
        XCTAssertEqual(FollowFinger.settleDirection(progress: -0.6, velocity: 3), 1)
        XCTAssertNil(FollowFinger.settleDirection(progress: 0, velocity: 3))
    }

    func testReleaseVelocityUsesTrackedMotionAndRespectsEdges() {
        var swipe = FollowedSwipe(speed: .smooth)
        swipe.track(progress: 0.7, velocity: 0)
        // The release reports no motion, so the tracked drag decides.
        XCTAssertEqual(swipe.releaseVelocity(progress: 0, velocity: 0, neighborExists: { _ in true }), 20)
        // No Space to settle on: leave macOS's rubber-band alone.
        XCTAssertNil(swipe.releaseVelocity(progress: 0, velocity: 0, neighborExists: { _ in false }))
        // Snapping back toward the start is always allowed.
        XCTAssertEqual(swipe.releaseVelocity(progress: 0.3, velocity: 0, neighborExists: { _ in false }), -20)
        XCTAssertNil(FollowedSwipe(speed: .smooth).releaseVelocity(progress: 0, velocity: 0, neighborExists: { _ in true }))
    }

    func testGesturePassesThroughAndOnlyReleaseIsReplaced() {
        let engine = FollowRecordingEngine()
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false },
                                           releaseSpeed: { .quick }, neighborExists: { _ in true })
        for (phase, progress) in [(Int64(1), 0.0), (2, 0.2), (2, 0.7)] {
            let sample = event(phase, progress: progress, velocity: 1)
            XCTAssertTrue(handle(sample, interceptor) === sample)
        }
        let companion = event(1, progress: 0, velocity: 0, cgsType: 29)
        XCTAssertTrue(handle(companion, interceptor) === companion)
        let end = event(4, progress: 0, velocity: 0)
        let released = handle(end, interceptor)
        XCTAssertNotNil(released)
        XCTAssertFalse(released === end)
        XCTAssertEqual(released.map(strafe_event_swipe_velocity_x), 40)
        XCTAssertEqual(released.map(strafe_event_gesture_phase), 4)
        XCTAssertEqual(strafe_event_swipe_velocity_x(end), 0)
        XCTAssertEqual(engine.attempts, 0)
    }

    func testCancelledAndOverlaySwipesAreLeftAlone() {
        var overlay = true
        let interceptor = SwipeInterceptor(engine: FollowRecordingEngine(), isExposeActive: { overlay },
                                           releaseSpeed: { .smooth }, neighborExists: { _ in true })
        for phase: Int64 in [1, 2, 4] {
            let sample = event(phase, progress: 0.7, velocity: 3)
            XCTAssertTrue(handle(sample, interceptor) === sample)
        }
        overlay = false
        _ = handle(event(1, progress: 0, velocity: 0), interceptor)
        _ = handle(event(2, progress: 0.7, velocity: 3), interceptor)
        let cancel = event(8, progress: 0.7, velocity: 3)
        XCTAssertTrue(handle(cancel, interceptor) === cancel)
        // A stray release after the cancel is not treated as part of it.
        let stray = event(4, progress: 0.7, velocity: 3)
        XCTAssertTrue(handle(stray, interceptor) === stray)
    }

    func testDisabledKeepsInstantMode() {
        let engine = FollowRecordingEngine()
        let interceptor = SwipeInterceptor(engine: engine, isExposeActive: { false },
                                           releaseSpeed: { nil }, neighborExists: { _ in true })
        XCTAssertNil(handle(event(1, progress: 0, velocity: 0), interceptor))
        XCTAssertNil(handle(event(2, progress: 0.2, velocity: 1), interceptor))
        XCTAssertEqual(engine.attempts, 1)
    }

    func testReleaseSpeedPresets() {
        let velocities = ReleaseSpeed.allCases.map(\.velocity)
        XCTAssertEqual(velocities, velocities.sorted())
        for speed in ReleaseSpeed.allCases { XCTAssertEqual(ReleaseSpeed(name: speed.name), speed) }
        XCTAssertNil(ReleaseSpeed(name: "fast"))
        XCTAssertEqual(ReleaseSpeed.default, .smooth)
    }

    private func handle(_ event: CGEvent, _ interceptor: SwipeInterceptor) -> CGEvent? {
        interceptor.handle(type: CGEventType(rawValue: 30)!, event: event)?.takeUnretainedValue()
    }

    private func event(_ phase: Int64, progress: Double, velocity: Double, cgsType: Int64 = 30) -> CGEvent {
        let event = CGEvent(source: nil)!
        event.setIntegerValueField(CGEventField(rawValue: 55)!, value: cgsType)
        event.setIntegerValueField(CGEventField(rawValue: 110)!, value: 23)
        event.setIntegerValueField(CGEventField(rawValue: 123)!, value: 1)
        event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
        event.setDoubleValueField(CGEventField(rawValue: 124)!, value: progress)
        event.setDoubleValueField(CGEventField(rawValue: 129)!, value: velocity)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }
}

private final class FollowRecordingEngine: SwitchEngine {
    var attempts = 0
    func switchSpace(_ direction: SwitchDirection) throws { attempts += 1 }
}
