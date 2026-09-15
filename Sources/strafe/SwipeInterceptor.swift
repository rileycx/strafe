import CoreGraphics
import Foundation
import CStrafe

/// Owns the `CGEventTap` that detects the user's real 3-finger horizontal
/// space-swipe, suppresses it, and fires the engine's instant switch instead
/// (SPEC §2).
///
/// Concurrency: the tap source is installed on the **main** run loop in
/// `kCFRunLoopCommonModes` (SPEC §2.1), so `eventTapCallback` always runs on
/// the main thread. All mutable gesture and lifecycle state
/// is therefore touched only from that single run loop and needs
/// no locking. The class is `@unchecked Sendable` because the C callback
/// reaches it through an opaque pointer; that confinement invariant is what
/// makes the unchecked conformance sound.
final class SwipeInterceptor: @unchecked Sendable {
    private let engine: SwitchEngine
    private let invertDirection: Bool
    private let overlayActive: @Sendable () -> Bool
    private let overlaySnapshot: @Sendable () -> Bool
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Whether the tap is currently created and enabled.
    var isRunning: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    /// Whether interception is active. When false the callback passes every
    /// event through untouched (SPEC §2.2: "only acts when swipeOverrideEnabled").
    var overrideEnabled: Bool = true {
        didSet {
            if overrideEnabled != oldValue { resetGesture() }
        }
    }

    // MARK: - State machine (SPEC §2.3). Main-run-loop confined.
    private enum GestureFamily: Int, Sendable {
        case legacy, fluid, generic
    }
    private var activeFamily: GestureFamily?
    private var swipeFired = false
    private let ownPID = Int64(ProcessInfo.processInfo.processIdentifier)
    private let diagnosticsEnabled = ProcessInfo.processInfo.environment["STRAFE_DIAGNOSTICS"] == "1"
    private let diagnosticsQueue = DispatchQueue(label: "strafe.swipe-diagnostics", qos: .utility)
    private var diagnosticBudget = 64
    private var diagnosticChangedFamilies = 0
    private var errorBudget = 8
    private var lastOwnedEvent: TimeInterval = 0

    private func resetGesture() {
        activeFamily = nil
        swipeFired = false
        lastOwnedEvent = 0
    }

    init(engine: SwitchEngine, configuration: SwitchConfiguration,
         overlayActive: @escaping @Sendable () -> Bool = { MissionControlMonitor.shared.isActive },
         overlaySnapshot: @escaping @Sendable () -> Bool = { strafe_is_expose_active() }) {
        self.engine = engine
        self.invertDirection = configuration.invertSwipeDirection
        self.overrideEnabled = configuration.interceptSwipes
        self.overlayActive = overlayActive
        self.overlaySnapshot = overlaySnapshot
    }

    // MARK: - Lifecycle

    /// Create the tap and add it to the main run loop. No-op if already running.
    func start() {
        guard eventTap == nil else {
            enable()
            return
        }

        // Gesture (1<<29) | dock-control (1<<30) | fluid-touch (1<<31).
        // Private type bits are single-sourced in C with the synthesizer. Key events
        // are intentionally excluded (they were never acted on and only added
        // per-keystroke latency) — see the determination comment in CStrafe.c.
        let mask = CGEventMask(strafe_tap_event_mask())

        // Trampoline `self` through the tap's userInfo pointer.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,          // SPEC §2.1: same location as posting
            place: .headInsertEventTap,       // head of the chain: see events before WindowServer
            options: .defaultTap,             // active tap: returning nil suppresses
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<SwipeInterceptor>
                    .fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handle(type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            FileHandle.standardError.write(
                Data("[SwipeInterceptor] failed to create event tap (accessibility not granted?)\n".utf8)
            )
            return
        }

        // SPEC §2.1: source added to the MAIN run loop in common modes.
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        self.eventTap = tap
        self.runLoopSource = source
        enable()
    }

    /// Enable the tap if it exists.
    func enable() {
        guard let eventTap else { return }
        if !CGEvent.tapIsEnabled(tap: eventTap) { resetGesture() }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    /// Disable the tap without tearing it down (can be re-enabled cheaply).
    func disable() {
        resetGesture()
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: false)
    }

    /// Fully remove the tap from the main run loop and release it.
    func teardown() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        resetGesture()
    }

    // MARK: - Callback (runs on the main run loop)

    // Internal so non-posting tests can replay captured gesture representations.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // HOT PATH — runs for every gesture/dock-control event the tap sees.
        // Invariant: the reject path (any non-candidate event) must do zero
        // allocations, no Swift string work, no logging, and acquire no lock.
        // `Unmanaged.passUnretained` only wraps the pointer (no ARC retain). The
        // engine lock is touched only inside `engine.switchSpace`, i.e. only once
        // a real swipe actually fires — never on pass-through. Keep it that way.
        let passthrough = Unmanaged.passUnretained(event)

        // SPEC §2.3 / §7.5: the system auto-disables the tap on timeout or
        // heavy user input. Re-enable and pass the event through, else the
        // override silently dies.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A disable can swallow a gesture's `ended`/`cancelled`, leaving the
            // state machine mid-track. Reset before re-enabling so a dropped
            // gesture-end can't leave us stuck suppressing companion events.
            resetGesture()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return passthrough
        }

        // Reject our output before *any* gesture/diagnostic state changes. The
        // marker also covers serialized output whose source PID is rewritten.
        let pid = strafe_event_source_pid(event)
        if pid == ownPID || strafe_event_is_strafe(event) { return passthrough }
        guard overrideEnabled || diagnosticsEnabled else { return passthrough }

        let cgsType = strafe_event_cgs_type(event)
        let dockControl = strafe_cgs_event_dock_control()
        let gesture = strafe_cgs_event_gesture()
        let family: GestureFamily
        let hid = strafe_event_hid_type(event)
        if cgsType == dockControl || cgsType == strafe_cgs_event_fluid_touch() {
            if cgsType == dockControl && pid != 0 { return passthrough }
            guard hid == strafe_iohid_event_dock_swipe() else { return passthrough }
            family = cgsType == dockControl ? .legacy : .fluid
        } else if cgsType == gesture && hid == strafe_iohid_event_generic_swipe() {
            family = .generic
        } else {
            // Unknown companion subtypes may be unrelated gestures. Never
            // blanket-suppress type29 merely because a swipe is active.
            return passthrough
        }

        // Decoding reference: jurplel/InstantSpaceSwitcher PR77, pinned at
        // 4602184328ec13b01e52e4456ad6ec3239df5152 (selective protocol findings).
        // HID32 as a *horizontal* swipe is empirically inferred, not proven for
        // every macOS 27 gesture. Its axis discriminator remains unresolved;
        // field123 is established only for HID23, so do not invent a HID32 check.
        let phase = strafe_event_gesture_phase(event)
        let progress = family == .generic
            ? strafe_event_generic_progress(event) : strafe_event_swipe_progress(event)
        diagnose(event: event, family: family, cgsType: cgsType, hid: hid,
                 pid: pid, phase: phase, progress: progress)
        guard overrideEnabled else { return passthrough }
        // This host's confirmed desktop stream is HID23. HID32 also appeared
        // during the user's overlay/navigation tests, without a known axis.
        // Observe it diagnostically, but do not own or suppress that stream.
        guard family != .generic else { return passthrough }
        if strafe_event_swipe_motion(event) != strafe_gesture_motion_horizontal() {
            return passthrough
        }

        if overlayActive() {
            resetGesture()
            return passthrough
        }
        let now = ProcessInfo.processInfo.systemUptime
        // Recover from an absent Ended without latching suppression forever.
        if activeFamily != nil && now - lastOwnedEvent > 0.5 { resetGesture() }

        if phase == strafe_gesture_phase_began() {
            if overlaySnapshot() {
                resetGesture()
                return passthrough
            }
            // Both duplicate Began and another representation's Began belong
            // to the current swipe; neither may reset the once-only fire latch.
            if activeFamily != nil { return nil }
            activeFamily = family
            swipeFired = false
            lastOwnedEvent = now
            return nil
        }

        guard let activeFamily else { return passthrough }
        // Window enumeration is intentionally restricted to Began. Repeating
        // it for every Changed event can stall the active input tap.
        // Only the family that began tracking can drive/fire/end this stream.
        // In particular, a companion Ended must not clear the owner's latch.
        guard family == activeFamily else { return nil }
        lastOwnedEvent = now

        if phase == strafe_gesture_phase_changed() {
            fireIfNeeded(progress)
        } else if phase == strafe_gesture_phase_ended() {
            // Generic progress119 is known; velocity129 is not established for
            // HID32. Preserve the velocity fallback only for HID23 paths.
            fireIfNeeded(family == .generic ? progress : strafe_event_swipe_velocity_x(event))
            let fired = swipeFired
            resetGesture()
            return fired ? nil : passthrough
        } else if phase == strafe_gesture_phase_cancelled() {
            resetGesture()
        }
        return nil
    }

    private func fireIfNeeded(_ value: Double) {
        guard !swipeFired, value.isFinite, value != 0 else { return }
        swipeFired = true
        do {
            // The engine enqueues asynchronously; never sleep in the tap.
            // Physical displacement and synthetic output have separate sign
            // conventions on macOS 27; never feed raw progress into bounds.
            try engine.switchSpace(Self.direction(for: value, inverted: invertDirection))
        } catch {
            guard errorBudget > 0 else { return }
            errorBudget -= 1
            diagnosticsQueue.async {
                FileHandle.standardError.write(Data("[SwipeInterceptor] switch failed: \(error) (first 8 errors only)\n".utf8))
            }
        }
    }

    static func direction(for progress: Double, inverted: Bool) -> SwitchDirection {
        ((progress > 0) != inverted) ? .right : .left
    }

    /// At most 64 candidate phase samples per instance, even when override is
    /// off. No CGEvent escapes the callback; formatting/I/O happen off-thread.
    private func diagnose(event: CGEvent, family: GestureFamily, cgsType: Int64,
                          hid: Int64, pid: Int64, phase: Int64, progress: Double) {
        guard diagnosticsEnabled, diagnosticBudget > 0 else { return }
        let bit = 1 << family.rawValue
        if phase == strafe_gesture_phase_began() {
            diagnosticChangedFamilies &= ~bit
        } else if phase == strafe_gesture_phase_changed() {
            guard diagnosticChangedFamilies & bit == 0 else { return }
            diagnosticChangedFamilies |= bit
        } else if phase != strafe_gesture_phase_ended() && phase != strafe_gesture_phase_cancelled() {
            return
        }
        diagnosticBudget -= 1
        let motion = strafe_event_swipe_motion(event)
        let progress119 = strafe_event_generic_progress(event)
        let progress124 = strafe_event_swipe_progress(event)
        let velocity = strafe_event_swipe_velocity_x(event)
        let enabled = overrideEnabled
        diagnosticsQueue.async {
            FileHandle.standardError.write(Data((
                "[SwipeInterceptor] candidate type=\(cgsType) hid=\(hid) pid=\(pid) phase=\(phase) " +
                "motion=\(motion) p119=\(progress119) p124=\(progress124) selected=\(progress) " +
                "vx=\(velocity) override=\(enabled) (64 sample cap)\n"
            ).utf8))
        }
    }
}
