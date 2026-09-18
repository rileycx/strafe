import CoreGraphics
import Foundation
import CStrafe

/// Owns the `CGEventTap` that detects the user's real 3-finger horizontal
/// space-swipe, suppresses it, and fires the engine's instant switch instead
/// (SPEC §2).
///
/// Concurrency: the tap source is installed on the **main** run loop in
/// `kCFRunLoopCommonModes` (SPEC §2.1), so `eventTapCallback` always runs on
/// the main thread. All mutable gesture and tap lifecycle state is
/// therefore touched only from that single run loop and needs
/// no locking. The class is `@unchecked Sendable` because the C callback
/// reaches it through an opaque pointer; that confinement invariant is what
/// makes the unchecked conformance sound.
final class SwipeInterceptor: @unchecked Sendable {
    private let engine: SwitchEngine
    private let isExposeActive: () -> Bool
    private var eventTap: (any SwipeEventTap)?
    private let accessibilityGranted: () -> Bool
    private let makeTap: (CGEventTapCallBack, UnsafeMutableRawPointer) -> (any SwipeEventTap)?
    private var recoveryTimer: Timer?
    private var wantsRunning = false
    private var reportedCreationFailure = false

    /// Whether the tap is currently created and enabled.
    var isRunning: Bool { eventTap?.isEnabled ?? false }

    var statusDescription: String {
        if !overrideEnabled { return "Swipe interception is paused" }
        if !accessibilityGranted() { return "Accessibility permission required" }
        return isRunning ? "Swipe interception is active" : "Waiting for gesture access — retrying automatically"
    }

    /// Whether interception is active. When false the callback passes every
    /// event through untouched (SPEC §2.2: "only acts when swipeOverrideEnabled").
    var overrideEnabled: Bool = true

    // MARK: - State machine (SPEC §2.3). Main-run-loop confined.
    private var swipeTracking = false
    private var swipeFired = false
    private var swipePosted = false

    init(engine: SwitchEngine,
         isExposeActive: @escaping () -> Bool = { strafe_is_expose_active() },
         accessibilityGranted: @escaping () -> Bool = { Permissions.isAccessibilityGranted },
         makeTap: @escaping (CGEventTapCallBack, UnsafeMutableRawPointer) -> (any SwipeEventTap)? = SystemSwipeEventTap.make) {
        self.engine = engine
        self.isExposeActive = isExposeActive
        self.accessibilityGranted = accessibilityGranted
        self.makeTap = makeTap
    }

    deinit {
        recoveryTimer?.invalidate()
        eventTap?.invalidate()
    }

    // MARK: - Lifecycle

    /// Keep trying until the tap exists, including when permission is granted
    /// after launch. The timer only checks trust/tap health; it reads no input.
    func start() {
        wantsRunning = true
        if recoveryTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                self?.recoverIfNeeded()
            }
            recoveryTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        recoverIfNeeded()
    }

    /// Reconcile permission and tap health without creating duplicate taps.
    func recoverIfNeeded() {
        guard wantsRunning else { return }
        guard accessibilityGranted() else {
            eventTap?.invalidate()
            eventTap = nil
            resetGesture()
            return
        }
        if let eventTap {
            if !eventTap.isEnabled {
                resetGesture()
                eventTap.enable()
                // A revoked/invalid tap may no longer be re-enableable.
                if !eventTap.isEnabled {
                    eventTap.invalidate()
                    self.eventTap = nil
                }
            }
            if self.eventTap != nil { return }
        }

        // Trampoline `self` through the tap's userInfo pointer.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = makeTap(
            { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<SwipeInterceptor>
                    .fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handle(type: type, event: event)
            },
            userInfo
        ) else {
            if !reportedCreationFailure {
                FileHandle.standardError.write(Data(
                    "[SwipeInterceptor] gesture tap unavailable; retrying automatically\n".utf8))
                reportedCreationFailure = true
            }
            return
        }
        self.eventTap = tap
        reportedCreationFailure = false
        tap.enable()
    }

    /// Enable the tap, creating it or retrying if permission is pending.
    func enable() {
        start()
    }

    /// Disable the tap without tearing it down (can be re-enabled cheaply).
    func disable() {
        wantsRunning = false
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        eventTap?.disable()
        resetGesture()
    }

    /// Fully remove the tap from the main run loop and release it.
    func teardown() {
        disable()
        eventTap?.invalidate()
        eventTap = nil
    }

    private func resetGesture() {
        swipeTracking = false
        swipeFired = false
        swipePosted = false
    }

    // MARK: - Callback (runs on the main run loop)

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
            if wantsRunning { eventTap?.enable() }
            return passthrough
        }

        // Only act when interception is on (SPEC §2.2).
        guard overrideEnabled else { return passthrough }

        // Read the private CGSEventType (field 55). We only care about the
        // dock-control swipe and its companion gesture events.
        let cgsType = strafe_event_cgs_type(event)
        let dockControl = strafe_cgs_event_dock_control()
        let gesture = strafe_cgs_event_gesture()

        guard cgsType == dockControl || cgsType == gesture else {
            return passthrough
        }

        // SPEC §2.2 step 3: real HID gestures originate in the kernel with
        // source pid == 0. Synthetic events (ours + any other app's) have a
        // nonzero pid — pass them through so we don't re-trap our own posts.
        if strafe_event_source_pid(event) != 0 {
            return passthrough
        }

        // Companion gesture events (type 29) are dropped while tracking (SPEC §2.3).
        if cgsType == gesture {
            return swipeTracking ? nil : passthrough
        }

        // From here: a real (pid 0) dock-control event.
        // SPEC §2.2 step 4: require a horizontal dock swipe; anything else
        // (vertical / App Exposé) passes through untouched.
        guard strafe_event_hid_type(event) == strafe_iohid_event_dock_swipe(),
              strafe_event_swipe_motion(event) == strafe_gesture_motion_horizontal()
        else {
            return passthrough
        }

        // SPEC §2.3 state machine, driven by the gesture phase (field 132).
        let phase = strafe_event_gesture_phase(event)

        if phase == strafe_gesture_phase_began() {
            // Let real gestures through while an overlay (Exposé) is up (SPEC §2.5).
            if isExposeActive() { return passthrough }
            swipeTracking = true
            swipeFired = false
            swipePosted = false
            return nil  // SUPPRESS the real 'began'

        } else if phase == strafe_gesture_phase_changed() {
            guard swipeTracking else { return passthrough }
            if !swipeFired {
                let progress = strafe_event_swipe_progress(event)
                if progress != 0.0 {
                    // Direction is the sign of progress; fire as soon as known.
                    let dir: SwitchDirection = strafe_event_moves_right(progress) ? .right : .left
                    fire(dir)
                }
            }
            return nil  // SUPPRESS

        } else if phase == strafe_gesture_phase_ended() {
            guard swipeTracking else { return passthrough }
            if !swipeFired {
                // Fallback: derive direction from the end velocity's sign.
                let velocity = strafe_event_swipe_velocity_x(event)
                if velocity != 0.0 {
                    let dir: SwitchDirection = strafe_event_moves_right(velocity) ? .right : .left
                    fire(dir)
                } else {
                    // Direction was never determined (no nonzero-progress
                    // `changed`, and zero end velocity), so strafe never acted on
                    // this gesture. Reset state and pass the original 'ended'
                    // through so the OS handles the gesture it still owns, rather
                    // than suppressing an event we never overrode.
                    swipeTracking = false
                    swipeFired = false
                    swipePosted = false
                    return passthrough
                }
            }
            let didPost = swipePosted
            swipeTracking = false
            swipeFired = false
            swipePosted = false
            if didPost && strafe_uses_iohid_payload() {
                // The Dock still needs the real terminal event to close its
                // native gesture state. Remove motion so it cannot switch twice.
                strafe_clear_swipe_motion(event)
                return passthrough
            }
            return nil  // SUPPRESS

        } else if phase == strafe_gesture_phase_cancelled() {
            swipeTracking = false
            swipeFired = false
            swipePosted = false
            return nil

        } else {
            // Any other phase (mayBegin/none): suppress only while tracking.
            return swipeTracking ? nil : passthrough
        }
    }

    private func fire(_ direction: SwitchDirection) {
        swipeFired = true
        do {
            try engine.switchSpace(direction)
            swipePosted = true
        } catch SwitchEngineError.atEdge {
            // Suppress the entire real gesture, including its terminal event,
            // when no neighboring Space exists. Passing the end through on
            // macOS 27 can trigger the Dock's blank-screen rubber-band effect.
        } catch {
            FileHandle.standardError.write(Data("[SwipeInterceptor] switch failed: \(error)\n".utf8))
        }
    }
}

/// The narrow lifecycle seam lets permission recovery be tested without
/// installing a system event tap or requesting test-runner Accessibility.
protocol SwipeEventTap: AnyObject {
    var isEnabled: Bool { get }
    func enable()
    func disable()
    func invalidate()
}

private final class SystemSwipeEventTap: SwipeEventTap {
    private let port: CFMachPort
    private let source: CFRunLoopSource

    var isEnabled: Bool {
        CFMachPortIsValid(port) && CGEvent.tapIsEnabled(tap: port)
    }

    static func make(callback: CGEventTapCallBack, userInfo: UnsafeMutableRawPointer) -> (any SwipeEventTap)? {
        // Gesture (29) and dock-control (30) only. Never keyboard events.
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: CGEventMask(strafe_tap_event_mask()),
            callback: callback, userInfo: userInfo
        ) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return SystemSwipeEventTap(port: port, source: source)
    }

    private init(port: CFMachPort, source: CFRunLoopSource) {
        self.port = port
        self.source = source
    }

    func enable() { CGEvent.tapEnable(tap: port, enable: true) }
    func disable() { CGEvent.tapEnable(tap: port, enable: false) }
    func invalidate() {
        disable()
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(port)
    }
}
