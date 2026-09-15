import CoreGraphics
import Foundation
import CStrafe

/// Low-level synthetic event posting for the harness: the native (animated)
/// Mission Control switch and the probe left-clicks. Kept separate from the
/// strafe switch (which goes through `strafe_post_switch_gesture`) so the two
/// "trigger" paths are obviously distinct in the measurement code.
///
/// Both modes now post the SAME private dock-swipe gesture family (the event
/// CStrafe.c synthesizes) — they differ only in the velocity/progress profile:
///
///   - strafe  (`StrafeSwitch.perform`): ±FLT_TRUE_MIN progress + a very high
///     velocity (2000) on all three phases. The WindowServer reads that as a
///     flick and jumps instantly, skipping the slide animation.
///   - native  (`postNativeSwitch` below): a real-swipe-shaped gesture — a
///     `began`, then a short ramp of `changed` events whose progress climbs
///     0 → ~0.35 over ~100ms, then an `ended` with a MODERATE velocity (order
///     100–400). Shaped like a human swipe, so macOS runs its standard ANIMATED
///     transition — which is exactly the baseline we want to measure.
///
/// This replaced an earlier Ctrl+Arrow approach: posting the synthetic
/// "Move left/right a space" Mission Control keyboard shortcut is a complete
/// no-op on macOS 26 (verified empirically on this machine — zero space changes
/// on either .cghidEventTap or .cgSessionEventTap, while clicks delivered fine).
/// The gesture route below drives the same WindowServer path a real trackpad
/// swipe does, so it actually switches.
enum EventPosting {
    /// The private field indices and enum constants come from CStrafe's C header
    /// (`strafe_field_*` / `strafe_*` accessors) so bench never re-hardcodes a
    /// magic number — they stay single-sourced in CStrafe.c (SPEC §1.2–1.3).
    private static let fieldCGSType     = CGEventField(rawValue: UInt32(strafe_field_cgs_event_type()))!
    private static let fieldHIDType     = CGEventField(rawValue: UInt32(strafe_field_hid_type()))!
    private static let fieldMotion      = CGEventField(rawValue: UInt32(strafe_field_swipe_motion()))!
    private static let fieldProgress    = CGEventField(rawValue: UInt32(strafe_field_swipe_progress()))!
    private static let fieldVelocityX   = CGEventField(rawValue: UInt32(strafe_field_swipe_velocity_x()))!
    private static let fieldVelocityY   = CGEventField(rawValue: UInt32(strafe_field_swipe_velocity_y()))!
    private static let fieldPhase       = CGEventField(rawValue: UInt32(strafe_field_gesture_phase()))!

    /// Number of `changed` events in the ramp and the total ramp duration. Tuned
    /// so the transition is the OS's STANDARD-speed animated switch (not an
    /// instant jump): progress climbs to `rampPeakProgress` across `rampSteps`
    /// events spread over `rampDurationMs`.
    private static let rampSteps = 8
    private static let rampDurationMs: Double = 120.0
    private static let rampPeakProgress: Double = 0.35
    /// Moderate end velocity (order 100–400). Sign carries direction. Enough for
    /// the WindowServer to complete the switch, small enough that it keeps the
    /// full animation rather than flicking instantly (contrast strafe's 2000).
    /// Kept toward the low end of that band so the OS runs a full-length slide
    /// (the animated baseline we want to measure), not a near-instant flick.
    private static let endVelocity: Double = 130.0

    /// Post one phase of a dock-swipe gesture with explicit progress + velocity.
    /// Mirrors CStrafe.c's `post_dock_swipe` construction field-for-field, but
    /// takes progress/velocity as parameters so we can shape a normal human-like
    /// swipe (ramped progress, moderate end velocity) instead of the instant
    /// ±FLT_TRUE_MIN / high-velocity variant.
    static func postDockSwipe(
        phase: Int64, progress: Double, velocity: Double
    ) {
        guard let ev = CGEvent(source: nil) else { return }
        ev.setIntegerValueField(fieldCGSType, value: strafe_cgs_event_dock_control())
        ev.setIntegerValueField(fieldHIDType, value: strafe_iohid_event_dock_swipe())
        ev.setIntegerValueField(fieldPhase, value: phase)
        ev.setDoubleValueField(fieldProgress, value: progress)
        ev.setIntegerValueField(fieldMotion, value: strafe_gesture_motion_horizontal())
        ev.setDoubleValueField(fieldVelocityX, value: velocity)
        ev.setDoubleValueField(fieldVelocityY, value: velocity)
        // Same tap location CStrafe posts to (kCGSessionEventTap).
        ev.post(tap: .cgSessionEventTap)
    }

    /// Trigger the native, ANIMATED Mission Control space switch with a
    /// normal-velocity synthetic dock-swipe — the same private gesture family
    /// strafe uses, but shaped like a real human swipe so macOS runs its standard
    /// slide transition. Sequence: `began` (progress 0) → a ramp of `changed`
    /// events with progress climbing toward `rampPeakProgress` over
    /// `rampDurationMs` → `ended` carrying a moderate `endVelocity`. Direction is
    /// the sign of both progress and velocity (right = positive).
    ///
    /// This is the baseline we measure against strafe: the user-visible animated
    /// switch, driven through the exact WindowServer path a real trackpad swipe
    /// uses. See the type-level note for why Ctrl+Arrow was abandoned.
    static func postNativeSwitch(_ direction: SwitchDirection) {
        let sign: Double = direction == .right ? 1.0 : -1.0

        // began: progress 0, no velocity yet.
        postDockSwipe(phase: strafe_gesture_phase_began(), progress: 0.0, velocity: 0.0)

        // changed: ramp progress 0 -> rampPeakProgress across rampSteps events,
        // sleeping between them so the whole ramp spans ~rampDurationMs. Real
        // swipes deliver a stream of moving-progress `changed` events; that
        // motion is what makes the OS animate rather than jump.
        let perStepSleep = UInt32((rampDurationMs / Double(rampSteps)) * 1000.0) // µs
        for step in 1...rampSteps {
            let frac = Double(step) / Double(rampSteps)
            let progress = sign * rampPeakProgress * frac
            // Instantaneous velocity ramps up with the swipe (moderate scale).
            let vel = sign * endVelocity * frac
            postDockSwipe(phase: strafe_gesture_phase_changed(), progress: progress, velocity: vel)
            usleep(perStepSleep)
        }

        // ended: moderate velocity, sign = direction. The OS completes the switch
        // WITH its normal animation (moderate velocity != instant flick).
        postDockSwipe(
            phase: strafe_gesture_phase_ended(),
            progress: sign * rampPeakProgress,
            velocity: sign * endVelocity
        )
    }

    /// Post one left-click (mouseDown+mouseUp pair) at a global CG point. Used as
    /// the interactivity probe: we spam these at the destination screen center
    /// and the destination window records when the first one is delivered.
    ///
    /// Reuses a single `CGEventSource`; the two events per call are unavoidable
    /// allocations, but the probe cadence (every 4 ms) makes that negligible and
    /// correctness (a real, deliverable click) matters more here.
    static func postProbeClick(at point: CGPoint, source: CGEventSource?) {
        guard let down = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseDown,
            mouseCursorPosition: point, mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: source, mouseType: .leftMouseUp,
            mouseCursorPosition: point, mouseButton: .left
        ) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
