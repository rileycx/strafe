import Foundation
import CStrafe

/// The direction to move between macOS Spaces.
enum SwitchDirection {
    case left
    case right

    var cDirection: StrafeDirection {
        self == .left ? StrafeDirectionLeft : StrafeDirectionRight
    }
}

/// Error surfaced when a synthetic switch could not be produced.
enum SwitchEngineError: Error {
    /// The bounds guard blocked a swipe past the first/last space (SPEC §2.4).
    case atEdge
    /// `CGEventCreate` failed — no event could be posted.
    case postFailed
}

/// Abstraction over the mechanism that actually moves between Spaces.
///
/// The real implementation (`GestureSwitchEngine`) posts synthetic
/// high-velocity dock-swipe gestures and is being specced separately.
/// Everything in this app is built against this protocol so the engine
/// can be swapped in without touching call sites.
protocol SwitchEngine {
    func switchSpace(_ direction: SwitchDirection) throws
}

/// No-op engine used during development, tests, and dry runs. Logs the
/// requested switch and returns. Kept around as a safe stand-in for the real
/// engine (e.g. when Accessibility isn't granted, or in unit tests).
struct StubSwitchEngine: SwitchEngine {
    func switchSpace(_ direction: SwitchDirection) throws {
        let arrow = direction == .left ? "←" : "→"
        FileHandle.standardError.write(
            Data("[StubSwitchEngine] switchSpace(\(arrow) \(direction))\n".utf8)
        )
    }
}

/// The real engine: posts a synthetic high-velocity dock-swipe gesture (SPEC
/// §1) to jump to the neighboring Space instantly.
///
/// Concurrency: `switchSpace` may be called from the main actor (hotkeys, CLI)
/// or from the event-tap run loop (the interceptor). All mutable prediction
/// state is guarded by an `NSLock`, so the type is safe to share across those
/// contexts; the actual CGEvent posting (`strafe_post_switch_gesture`) is a
/// stateless C call.
final class GestureSwitchEngine: SwitchEngine, @unchecked Sendable {
    /// Gesture velocity magnitude. 2000.0 is the "Instant" preset — the only
    /// value that truly skips the slide animation (SPEC §1.4, §5). Lower values
    /// keep a (shortened) animation.
    static let instantVelocity: Double = 2000.0

    private let velocity: Double
    private let spaceInfo: @Sendable () -> StrafeInfo?

    /// Per-display predicted current-space index, keyed by display UUID
    /// (SPEC §2.4). Avoids rebounding off the laggy live active-space query.
    /// Also guards `speed`.
    private let lock = NSLock()
    private var predictions: [String: UInt32] = [:]
    private var speed: TransitionSpeed = .default

    /// Serial queue for the ramped (animated) transition speeds.
    ///
    /// Ramps spread their posts over time. `switchSpace` is called from the
    /// event-tap callback on the **main run loop**, so sleeping there would
    /// stall the tap and every other main-thread client during the animation.
    ///
    /// Serial, not concurrent, and deliberately so: two swipes in quick
    /// succession must not interleave their began/changed/ended streams. The
    /// second ramp starts only once the first has posted its `ended`.
    private let rampQueue = DispatchQueue(
        label: "com.rileycx.strafe.ramp", qos: .userInteractive
    )

    init(velocity: Double = GestureSwitchEngine.instantVelocity,
         spaceInfo: @escaping @Sendable () -> StrafeInfo? = {
             var info = StrafeInfo()
             return strafe_get_space_info(&info) ? info : nil
         }) {
        self.velocity = velocity
        self.spaceInfo = spaceInfo
    }

    /// Whether the private CGS topology symbols resolved (SPEC §1.1, §6).
    var cgsAvailable: Bool { strafe_cgs_available() }

    /// The current transition speed. Read/written under the same lock as the
    /// predictions because the menu (main actor) sets it while the event-tap
    /// callback reads it.
    var transitionSpeed: TransitionSpeed {
        lock.lock(); defer { lock.unlock() }
        return speed
    }

    func setTransitionSpeed(_ newValue: TransitionSpeed) {
        lock.lock()
        speed = newValue
        lock.unlock()
    }

    /// Block until any in-flight ramp has finished posting.
    ///
    /// Only CLI mode needs this: it issues one switch and then exits the
    /// process, which would kill a ramp partway through its `changed` stream and
    /// leave the gesture unfinished. The menu-bar app never calls it — blocking
    /// there is exactly what `rampQueue` exists to avoid.
    func waitForPendingSwitch() {
        rampQueue.sync {}
    }

    /// Post one directional switch in whatever shape the current speed calls for.
    ///
    /// Returns whether the switch was *dispatched*, not whether it completed:
    /// the instant path posts synchronously and can report a failed
    /// `CGEventCreate`, while a ramp is handed to `rampQueue` and returns true
    /// immediately. Either way the caller's optimistic prediction update is
    /// correct, because that models where we are going, not where we are.
    private func post(_ direction: SwitchDirection, speed: TransitionSpeed, spaceCount: UInt32?) -> Bool {
        guard let rampMs = speed.rampMilliseconds else {
            return strafe_post_switch_gesture(direction.cDirection, velocity)
        }

        let sign: Double = direction == .right ? 1.0 : -1.0
        // Keep the short presets' sampling, but don't stretch eight updates
        // across a slow ramp. Aim for at least one update per 120 Hz frame.
        let steps = max(TransitionSpeed.rampSteps, Int((rampMs * 120 / 1_000).rounded(.up)))
        // Dock divides drag input by the display's Space count, but adjacent
        // Space positions are spaced 1 / (count - 1) apart. A raw 1.0 stops at
        // two-thirds of a slide when there are three Spaces.
        let travel: Double
        if let spaceCount, spaceCount > 1 {
            travel = sign * Double(spaceCount) / Double(spaceCount - 1)
        } else {
            travel = sign
        }
        let stepNanos = UInt64(rampMs * 1_000_000 / Double(steps))

        rampQueue.async {
            // began: at rest. The motion in the `changed` stream below is what
            // makes the WindowServer animate instead of jumping.
            _ = strafe_post_dock_swipe_phase(strafe_gesture_phase_began(), 0.0, 0.0)
            let start = DispatchTime.now().uptimeNanoseconds
            for step in 1...steps {
                let frac = Double(step) / Double(steps)
                let eased = frac * frac * (3.0 - 2.0 * frac)
                _ = strafe_post_dock_swipe_phase(
                    strafe_gesture_phase_changed(),
                    travel * eased,
                    0.0
                )
                // Sleep to a fixed deadline so posting and wake-up overhead
                // don't accumulate across the ramp.
                let deadline = start + UInt64(step) * stepNanos
                let now = DispatchTime.now().uptimeNanoseconds
                if now < deadline {
                    usleep(UInt32((deadline - now + 999) / 1_000))
                }
            }
            // Dock feeds release velocity into its spring. We already drove
            // the slide to the target, so end at rest instead of adding a kick.
            _ = strafe_post_dock_swipe_phase(
                strafe_gesture_phase_ended(), travel, 0.0
            )
        }
        return true
    }

    func switchSpace(_ direction: SwitchDirection) throws {
        // Read live topology once. If CGS symbols are unavailable we can't do
        // bounds/prediction bookkeeping — fall back to posting unconditionally.
        if let info = spaceInfo() {
            let displayID = withUnsafeBytes(of: info.displayID) { raw -> String in
                let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                return String(cString: ptr)
            }

            lock.lock()
            let current = predictions[displayID] ?? info.currentIndex

            // Bounds guard (SPEC §2.4): never swipe past the first/last space.
            if direction == .left {
                if current == 0 { lock.unlock(); throw SwitchEngineError.atEdge }
            } else {
                if current + 1 >= info.spaceCount { lock.unlock(); throw SwitchEngineError.atEdge }
            }

            let target: UInt32 = direction == .left ? current - 1 : current + 1
            let shape = speed
            lock.unlock()

            guard post(direction, speed: shape, spaceCount: info.spaceCount) else {
                throw SwitchEngineError.postFailed
            }

            // Advance the optimistic prediction only after a successful post.
            lock.lock()
            predictions[displayID] = target
            lock.unlock()
        } else {
            guard post(direction, speed: transitionSpeed, spaceCount: nil) else {
                throw SwitchEngineError.postFailed
            }
        }
    }

    /// Reset all predictions to live CGS data. Call on
    /// `NSWorkspace.activeSpaceDidChangeNotification` (SPEC §2.4, §5) so rapid
    /// repeated swipes don't overshoot bounds or snap back off a stale index.
    func resetPredictions() {
        lock.lock()
        predictions.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
