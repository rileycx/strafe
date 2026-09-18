import Foundation
import XCTest
@testable import strafe

final class DockOverlayTests: XCTestCase {
    func testNormalDockIgnoresPersistentLayer20Window() {
        XCTAssertFalse(DockOverlayMonitor.resolveOverlay(identifiers: [], fallback: { true }))
        XCTAssertFalse(DockOverlayMonitor.resolveOverlay(identifiers: ["other"], fallback: { true }))
    }

    func testMissionControlAndExposeRemainPassthrough() {
        XCTAssertTrue(DockOverlayMonitor.resolveOverlay(identifiers: ["mc"], fallback: { false }))
        XCTAssertTrue(DockOverlayMonitor.resolveOverlay(identifiers: ["appexpose"], fallback: { false }))
    }

    func testUnavailableAccessibilityKeepsLegacyFallback() {
        XCTAssertTrue(DockOverlayMonitor.resolveOverlay(identifiers: nil, fallback: { true }))
        XCTAssertFalse(DockOverlayMonitor.resolveOverlay(identifiers: nil, fallback: { false }))
    }

    func testBackgroundProbeNeverPublishesAfterStop() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let monitor = DockOverlayMonitor(query: {
            entered.signal()
            _ = release.wait(timeout: .now() + 2)
            finished.signal()
            return true
        })
        monitor.start()
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        monitor.stop()
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(monitor.isActive)
    }
}
