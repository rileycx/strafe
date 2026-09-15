import AppKit
import Foundation
import CStrafe

// bench sweep — which gesture SHAPES actually switch a Space, and how fast?
//
// WHY THIS EXISTS: issue #1 proposes user-selectable "transition speed" presets
// implemented by varying ONLY the dock-swipe velocity field (40/50/60/80/2000)
// while `post_dock_swipe` keeps progress pinned at ±FLT_TRUE_MIN and fires
// began/changed/ended back-to-back with no delay (CStrafe.c:82-109).
//
// That is a different axis from the one this harness already found to control
// animation: `EventPosting.postNativeSwitch` produces the OS's animated slide
// via a PROGRESS RAMP (0 -> 0.35 over ~120ms) plus a moderate end velocity.
// So the open question is whether velocity-at-zero-progress is a speed knob at
// all, or just a pass/fail threshold on "is this a flick".
//
// This sweep answers that empirically rather than by reading the code.
//
// WHAT IT MEASURES: for each shape, "did the active Space actually change" and
// "how long until CGS reports the new Space". The second number INCLUDES the
// known reporting lag of the active-space query (the same lag that forces the
// app to keep a prediction dictionary — SPEC §2.4), so it is NOT an animation
// duration. It is only used as a DISCRIMINATOR: shapes that animate differently
// should separate on it; shapes that land identically should not.

/// One gesture shape to characterise.
struct SweepShape {
    let label: String
    /// Post via the SHIPPED poster (`strafe_post_switch_gesture`) at this
    /// velocity — zero-progress flick, exactly what issue #1's presets do.
    /// `nil` means use the ramped shape below instead.
    let flickVelocity: Double?
    /// Ramped shape: progress climbs to `peakProgress` over `rampMs`, then
    /// `ended` carries `endVelocity`. This is `postNativeSwitch`'s recipe,
    /// parameterised so the ramp duration itself can be swept.
    let rampMs: Double
    let rampSteps: Int
    let peakProgress: Double
    let endVelocity: Double

    static func flick(_ label: String, velocity: Double) -> SweepShape {
        SweepShape(label: label, flickVelocity: velocity,
                   rampMs: 0, rampSteps: 0, peakProgress: 0, endVelocity: 0)
    }

    static func ramp(_ label: String, ms: Double, endVelocity: Double = 130.0) -> SweepShape {
        SweepShape(label: label, flickVelocity: nil,
                   rampMs: ms, rampSteps: 8, peakProgress: 0.35, endVelocity: endVelocity)
    }
}

struct SweepTrial {
    let switched: Bool
    /// ms from post to the first CGS read reporting a different Space index.
    let reportedMs: Double?
    let from: UInt32
    let to: UInt32?
}

@MainActor
enum Sweep {
    /// Zero-progress flicks at issue #1's five preset velocities, then the
    /// ramped shape at several durations. If the presets are a real speed knob,
    /// the first block should separate; if animation lives on the ramp axis, the
    /// second block should separate and the first should not.
    static let shapes: [SweepShape] = [
        .flick("issue#1 Normal   (v=40)",   velocity: 40),
        .flick("issue#1 Fast     (v=50)",   velocity: 50),
        .flick("issue#1 Faster   (v=60)",   velocity: 60),
        .flick("issue#1 Fastest  (v=80)",   velocity: 80),
        .flick("shipped Instant  (v=2000)", velocity: 2000),
        .ramp("ramp  30ms + endV=130", ms: 30),
        .ramp("ramp  60ms + endV=130", ms: 60),
        .ramp("ramp 120ms + endV=130", ms: 120),
    ]

    // MARK: - Space topology

    static func spaceInfo() -> (index: UInt32, count: UInt32)? {
        var info = StrafeInfo()
        guard strafe_get_space_info(&info) else { return nil }
        return (info.currentIndex, info.spaceCount)
    }

    /// Poll until two consecutive reads agree, so a trial never starts while an
    /// earlier transition is still settling (this is what made an earlier,
    /// buggy version of this kind of measurement self-contradictory).
    @discardableResult
    static func settle(timeoutMs: Double = 2500) -> UInt32? {
        let deadline = Date().addingTimeInterval(timeoutMs / 1000)
        var last: UInt32? = nil
        while Date() < deadline {
            guard let now = spaceInfo()?.index else { return nil }
            if let last, last == now { return now }
            last = now
            usleep(30_000)
        }
        return last
    }

    // MARK: - Posting

    static func post(_ shape: SweepShape, _ direction: SwitchDirection) {
        if let velocity = shape.flickVelocity {
            // The REAL shipped path, so this measures issue #1 exactly as specced.
            _ = strafe_post_switch_gesture(
                direction == .right ? StrafeDirectionRight : StrafeDirectionLeft, velocity
            )
            return
        }

        let sign: Double = direction == .right ? 1.0 : -1.0
        EventPosting.postDockSwipe(
            phase: strafe_gesture_phase_began(), progress: 0.0, velocity: 0.0)
        let perStep = UInt32((shape.rampMs / Double(shape.rampSteps)) * 1000.0)
        for step in 1...shape.rampSteps {
            let frac = Double(step) / Double(shape.rampSteps)
            EventPosting.postDockSwipe(
                phase: strafe_gesture_phase_changed(),
                progress: sign * shape.peakProgress * frac,
                velocity: sign * shape.endVelocity * frac
            )
            if perStep > 0 { usleep(perStep) }
        }
        EventPosting.postDockSwipe(
            phase: strafe_gesture_phase_ended(),
            progress: sign * shape.peakProgress,
            velocity: sign * shape.endVelocity
        )
    }

    // MARK: - Trial

    static func trial(_ shape: SweepShape, timeoutMs: Double = 2000) -> SweepTrial? {
        guard let start = settle(), let info = spaceInfo() else { return nil }

        // Stay inside bounds: at an edge there is only one legal direction.
        let direction: SwitchDirection
        if start == 0 { direction = .right }
        else if start + 1 >= info.count { direction = .left }
        else { direction = Bool.random() ? .left : .right }

        let t0 = Date()
        post(shape, direction)

        let deadline = t0.addingTimeInterval(timeoutMs / 1000)
        while Date() < deadline {
            if let now = spaceInfo()?.index, now != start {
                return SweepTrial(
                    switched: true,
                    reportedMs: Date().timeIntervalSince(t0) * 1000,
                    from: start, to: now
                )
            }
            usleep(2_000)
        }
        return SweepTrial(switched: false, reportedMs: nil, from: start, to: nil)
    }

    // MARK: - Run

    static func run(trials: Int) {
        guard let info = spaceInfo() else {
            log("cannot read space topology (CGS unavailable) — aborting")
            return
        }
        log("space count=\(info.count), starting at index=\(info.index), \(trials) trials per shape")
        log("")
        log(String(format: "%-26@ %-9@ %-24@",
                   "shape" as NSString, "switched" as NSString,
                   "reported (ms) med/min/max" as NSString))
        log(String(repeating: "-", count: 62))

        for shape in shapes {
            var results: [SweepTrial] = []
            for _ in 0..<trials {
                guard let t = trial(shape) else { continue }
                results.append(t)
                // Let the WindowServer fully finish before the next trial.
                usleep(400_000)
            }
            let ok = results.filter(\.switched)
            let times = ok.compactMap(\.reportedMs).sorted()
            let stat: String
            if times.isEmpty {
                stat = "—"
            } else {
                stat = String(format: "%.0f / %.0f / %.0f",
                              times[times.count / 2], times.first!, times.last!)
            }
            log(String(format: "%-26@ %-9@ %-24@",
                       shape.label as NSString,
                       "\(ok.count)/\(results.count)" as NSString,
                       stat as NSString))
        }

        log("")
        log("NOTE: 'reported' includes CGS active-space reporting lag and is a")
        log("      DISCRIMINATOR, not an animation duration. Equal numbers mean")
        log("      the shapes are not distinguishable on this axis.")
        log("sweep done")
    }

    static func log(_ message: String) {
        FileHandle.standardError.write(Data("[sweep] \(message)\n".utf8))
    }
}
