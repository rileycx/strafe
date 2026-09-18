import CoreGraphics
import CStrafe
import XCTest
@testable import strafe

final class SwipeRecoveryTests: XCTestCase {
    func testPermissionGrantedAfterLaunchStartsTapWithoutRestart() {
        var granted = false
        var attempts = 0
        let tap = FakeSwipeEventTap()
        let interceptor = SwipeInterceptor(engine: StubSwitchEngine(), accessibilityGranted: { granted }, makeTap: { _, _ in
            attempts += 1
            return tap
        })
        defer { interceptor.teardown() }
        interceptor.start()
        XCTAssertEqual(attempts, 0)
        XCTAssertFalse(interceptor.isRunning)
        XCTAssertEqual(interceptor.statusDescription, "Accessibility permission required")

        granted = true
        interceptor.recoverIfNeeded()
        XCTAssertEqual(attempts, 1)
        XCTAssertTrue(interceptor.isRunning)
        interceptor.recoverIfNeeded()
        XCTAssertEqual(attempts, 1, "Healthy taps must not be recreated every second")
    }

    func testCreationFailureRetriesEvenWhenPermissionAlreadyGranted() {
        var attempts = 0
        let tap = FakeSwipeEventTap()
        let interceptor = SwipeInterceptor(engine: StubSwitchEngine(), accessibilityGranted: { true }, makeTap: { _, _ in
            attempts += 1
            return attempts == 1 ? nil : tap
        })
        defer { interceptor.teardown() }
        interceptor.start()
        XCTAssertFalse(interceptor.isRunning)
        XCTAssertTrue(interceptor.statusDescription.contains("retrying automatically"))
        interceptor.recoverIfNeeded()
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(interceptor.isRunning)
    }

    func testScheduledRecoveryRetriesWithoutUserAction() {
        var granted = false
        let tap = FakeSwipeEventTap()
        let interceptor = SwipeInterceptor(engine: StubSwitchEngine(), accessibilityGranted: { granted }, makeTap: { _, _ in tap })
        defer { interceptor.teardown() }
        interceptor.start()
        granted = true
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        XCTAssertTrue(interceptor.isRunning, "Granting permission must recover without an app restart or menu action")
    }

    func testInvalidTapIsRecreatedWhenReenablingFails() {
        var taps: [FakeSwipeEventTap] = []
        let interceptor = SwipeInterceptor(engine: StubSwitchEngine(), accessibilityGranted: { true }, makeTap: { _, _ in
            let tap = FakeSwipeEventTap()
            taps.append(tap)
            return tap
        })
        defer { interceptor.teardown() }
        interceptor.start()
        taps[0].invalidate()
        interceptor.recoverIfNeeded()
        XCTAssertTrue(interceptor.isRunning)
        XCTAssertEqual(taps.count, 2)
    }

    func testRevocationAndRegrantRecreateTap() {
        var granted = true
        var taps: [FakeSwipeEventTap] = []
        let interceptor = SwipeInterceptor(engine: StubSwitchEngine(), accessibilityGranted: { granted }, makeTap: { _, _ in
            let tap = FakeSwipeEventTap()
            taps.append(tap)
            return tap
        })
        defer { interceptor.teardown() }
        interceptor.start()
        granted = false
        interceptor.recoverIfNeeded()
        XCTAssertFalse(interceptor.isRunning)
        XCTAssertTrue(taps[0].invalidated)
        granted = true
        interceptor.recoverIfNeeded()
        XCTAssertTrue(interceptor.isRunning)
        XCTAssertEqual(taps.count, 2)
    }

    func testDisabledOrTornDownInterceptorDoesNotRestart() {
        var attempts = 0
        let interceptor = SwipeInterceptor(engine: StubSwitchEngine(), accessibilityGranted: { true }, makeTap: { _, _ in
            attempts += 1
            return FakeSwipeEventTap()
        })
        interceptor.start()
        interceptor.disable()
        interceptor.recoverIfNeeded()
        XCTAssertFalse(interceptor.isRunning)
        XCTAssertEqual(attempts, 1)
        interceptor.enable()
        XCTAssertTrue(interceptor.isRunning)
        interceptor.teardown()
        interceptor.recoverIfNeeded()
        XCTAssertFalse(interceptor.isRunning)
        XCTAssertEqual(attempts, 1)
    }

    func testActualTapDisabledStateIsReportedAndRecovers() {
        let tap = FakeSwipeEventTap()
        let interceptor = SwipeInterceptor(engine: StubSwitchEngine(), accessibilityGranted: { true }, makeTap: { _, _ in tap })
        defer { interceptor.teardown() }
        interceptor.start()
        tap.disable()
        XCTAssertFalse(interceptor.isRunning)
        interceptor.recoverIfNeeded()
        XCTAssertTrue(interceptor.isRunning)
    }

    func testGestureOnlyEventMaskIsUnchanged() {
        XCTAssertEqual(strafe_tap_event_mask(), (UInt64(1) << 29) | (UInt64(1) << 30))
    }
}

private final class FakeSwipeEventTap: SwipeEventTap {
    private(set) var isEnabled = false
    private(set) var invalidated = false
    func enable() { if !invalidated { isEnabled = true } }
    func disable() { isEnabled = false }
    func invalidate() { disable(); invalidated = true }
}
