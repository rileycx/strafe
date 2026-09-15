import Foundation
import CoreGraphics
import CStrafe

enum SwitchDirection: Sendable {
    case left
    case right

    var cDirection: StrafeDirection {
        self == .left ? StrafeDirectionLeft : StrafeDirectionRight
    }
}

enum SwitchEngineError: Error, Sendable {
    case atEdge
    case postFailed
    case topologyUnavailable
    case unexpectedChange
    case observationTimedOut
    case queueFull
    case pendingDropped
    case overlayActive
}

protocol SwitchEngine {
    /// Enqueues only; asynchronous failures are reported by the real engine.
    func switchSpace(_ direction: SwitchDirection) throws
}

struct StubSwitchEngine: SwitchEngine {
    func switchSpace(_ direction: SwitchDirection) throws {
        SwitchDiagnostics.log("[StubSwitchEngine] switchSpace(\(direction))")
    }
}

/// All request/event/observation state is confined to `queue`. Admission is
/// lock-protected so even requests waiting for that queue have a bounded count.
/// Scheduled closures retain the engine through completion (including in CLI).
final class GestureSwitchEngine: SwitchEngine, @unchecked Sendable {
    typealias Completion = @Sendable (Result<Void, SwitchEngineError>) -> Void
    static let instantVelocity: Double = 2000.0
    private let velocity: Double
    private let configuration: SwitchConfiguration
    private let dependencies: Dependencies
    private let queue = DispatchQueue(label: "strafe.switch-engine")
    private let admission = NSLock()
    private var admitted = 0
    private var generation: UInt64 = 0
    private var pending: [Request] = []
    private var active: Request?
    private var events: [CGEvent] = []
    private var origin: Topology?
    private var target: UInt32 = 0
    private var deadline: TimeInterval = 0
    private var candidateID: UInt64?
    private var candidateSince: TimeInterval = 0
    private var deliveryFailureHandler: (@Sendable (SwitchEngineError) -> Void)?

    private struct Request: Sendable {
        let id = UUID()
        let direction: SwitchDirection
        let completion: Completion?
    }

    /// The transition speed (SPEC §1.4). Written from the main actor (menu,
    /// CLI) and read on `queue` at request execution, hence its own lock.
    /// Ramps are scheduled phase-by-phase on `queue` — never slept inside the
    /// event tap — so a whole triplet can never interleave with another's.
    private let speedLock = NSLock()
    private var speed: TransitionSpeed = .default
    private var activeGapMS: Double = 0
    private var anomalies = 0
    private var lastOverlaySeen: TimeInterval = 0

    struct Topology: Sendable {
        let display: String
        let index: UInt32
        let count: UInt32
        let id: UInt64

        var summary: String { "display=\(display) index=\(index) count=\(count) currentID=\(id)" }

        static func read(display: String? = nil) -> Topology? {
            var info = StrafeInfo()
            let available: Bool
            if let display {
                available = display.withCString { strafe_get_space_info_for_display($0, &info) }
            } else {
                available = strafe_get_space_info(&info)
            }
            guard available, info.spaceCount > 0, info.currentIndex < info.spaceCount,
                  info.currentSpaceID != 0 else { return nil }
            let name = withUnsafeBytes(of: info.displayID) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            guard !name.isEmpty, display == nil || display == name else { return nil }
            return Topology(display: name, index: info.currentIndex, count: info.spaceCount, id: info.currentSpaceID)
        }
    }

    /// The test seam substitutes topology and event delivery; tests never post
    /// real gestures or require a particular desktop layout.
    struct Dependencies: Sendable {
        var read: @Sendable (String?) -> Topology? = { Topology.read(display: $0) }
        var build: @Sendable (SwitchDirection, Double, Int64, Bool, Bool) -> CGEvent? = {
            strafe_create_switch_event($0.cDirection, $1, $2, $3, $4)
        }
        var buildRamp: @Sendable (SwitchDirection, Double, Int64, Double, Bool, Bool) -> CGEvent? = {
            strafe_create_ramp_event($0.cDirection, $1, $2, $3, $4, $5)
        }
        var post: @Sendable (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }
        var overlayActive: @Sendable () -> Bool = { MissionControlMonitor.shared.isActive }
    }

    init(velocity: Double = GestureSwitchEngine.instantVelocity,
         configuration: SwitchConfiguration, dependencies: Dependencies = Dependencies()) {
        self.velocity = velocity
        self.configuration = configuration
        self.dependencies = dependencies
        if configuration.diagnostics { SwitchDiagnostics.log("startup \(configuration.summary)") }
    }

    var cgsAvailable: Bool { strafe_cgs_available() }
    var topologyStatus: String { Topology.read()?.summary ?? "unavailable" }

    func switchSpace(_ direction: SwitchDirection) throws {
        try switchSpace(direction, completion: nil)
    }

    /// Completion runs on the engine queue, exactly once for an admitted request.
    /// A synchronous admission error throws without invoking completion.
    func switchSpace(_ direction: SwitchDirection, completion: Completion?) throws {
        admission.lock()
        guard admitted < 16 else {
            admission.unlock()
            SwitchDiagnostics.log("request direction=\(direction) rejected: queueFull")
            throw SwitchEngineError.queueFull
        }
        admitted += 1
        let epoch = generation
        let request = Request(direction: direction, completion: completion)
        queue.async {
            self.admission.lock()
            let stale = epoch != self.generation
            self.admission.unlock()
            if stale {
                self.complete(request, .failure(.pendingDropped))
                return
            }
            self.pending.append(request)
            self.startNext()
        }
        // Preserve admission order even when callers arrive on different threads.
        admission.unlock()
    }

    /// Kept for the workspace notification seam. Live polling is authoritative;
    /// notifications must not invalidate a legitimate in-flight transition.
    func resetPredictions() {}

    /// Restore native swiping if replacement delivery is not behaving as
    /// expected. Ordinary boundaries and overlay passthrough are not failures.
    func setDeliveryFailureHandler(_ handler: @escaping @Sendable (SwitchEngineError) -> Void) {
        queue.async { self.deliveryFailureHandler = handler }
    }

    /// The current transition speed (SPEC §1.4). The menu (main actor) and CLI
    /// set it while the event-tap callback reads it, hence the lock. Read once
    /// per request at execution; a change mid-flight applies to the next swipe.
    var transitionSpeed: TransitionSpeed {
        speedLock.lock(); defer { speedLock.unlock() }
        return speed
    }

    func setTransitionSpeed(_ newValue: TransitionSpeed) {
        speedLock.lock()
        speed = newValue
        speedLock.unlock()
    }

    private func trace(_ message: String) {
        if configuration.diagnostics { SwitchDiagnostics.log(message) }
    }

    /// True when an overlay is up, recording the sighting for the failure
    /// grace period. All queue-confined callers use this instead of reading
    /// the dependency directly.
    private func overlayUp() -> Bool {
        guard dependencies.overlayActive() else { return false }
        lastOverlaySeen = ProcessInfo.processInfo.systemUptime
        return true
    }

    private func startNext() {
        guard active == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        active = request
        anomalies = 0
        guard !overlayUp() else {
            finish(.failure(.overlayActive), dropPending: true)
            return
        }
        guard let live = dependencies.read(nil) else {
            trace("request=\(request.id) direction=\(request.direction) live=unavailable predicted=none target=unavailable")
            finish(.failure(.topologyUnavailable), dropPending: true)
            return
        }
        origin = live
        let atEdge = request.direction == .left ? live.index == 0 : live.index == live.count - 1
        speedLock.lock()
        let shape = speed
        speedLock.unlock()
        trace("request=\(request.id) direction=\(request.direction) speed=\(shape.name) live={\(live.summary)} predicted=none target=\(atEdge ? "edge" : String(request.direction == .left ? live.index - 1 : live.index + 1))")
        guard !atEdge else { finish(.failure(.atEdge)); return }
        target = request.direction == .left ? live.index - 1 : live.index + 1
        // Allocate the whole sequence before posting Began. A builder failure
        // must not strand Dock with a partially constructed gesture.
        if let rampMs = shape.rampMilliseconds {
            activeGapMS = rampMs / Double(TransitionSpeed.rampSteps)
            let peak = TransitionSpeed.rampPeakProgress
            let endVelocity = TransitionSpeed.rampEndVelocity
            var sequence: [(phase: Int64, progress: Double, velocity: Double)] =
                [(strafe_gesture_phase_began(), 0.0, 0.0)]
            for step in 1...TransitionSpeed.rampSteps {
                let frac = Double(step) / Double(TransitionSpeed.rampSteps)
                sequence.append((strafe_gesture_phase_changed(), peak * frac, endVelocity * frac))
            }
            sequence.append((strafe_gesture_phase_ended(), peak, endVelocity))
            for (phase, progress, stepVelocity) in sequence {
                guard let event = dependencies.buildRamp(request.direction, stepVelocity, phase,
                                                         progress, configuration.augmented,
                                                         configuration.inverted) else {
                    finish(.failure(.postFailed), dropPending: true)
                    return
                }
                events.append(event)
            }
        } else {
            activeGapMS = configuration.phaseGapMS
            for phase in [strafe_gesture_phase_began(), strafe_gesture_phase_changed(), strafe_gesture_phase_ended()] {
                guard let event = dependencies.build(request.direction, velocity, phase,
                                                     configuration.augmented, configuration.inverted) else {
                    finish(.failure(.postFailed), dropPending: true)
                    return
                }
                events.append(event)
            }
        }
        // Posting routes via the cursor. Recheck after construction and before
        // Began; all subsequent observation stays pinned to this display.
        guard let routed = dependencies.read(nil), routed.display == live.display,
              routed.id == live.id, routed.index == live.index, routed.count == live.count else {
            finish(.failure(.unexpectedChange), dropPending: true)
            return
        }
        postPhase(0)
    }

    private func postPhase(_ index: Int) {
        guard let request = active else { return }
        if overlayUp() {
            // An overlay opened between phases. Close our partial synthetic
            // gesture before dropping queued requests; never leave it Began.
            if index > 0, let cancelled = dependencies.build(request.direction, velocity,
                strafe_gesture_phase_cancelled(), configuration.augmented, configuration.inverted) {
                dependencies.post(cancelled)
            }
            finish(.failure(.overlayActive), dropPending: true)
            return
        }
        dependencies.post(events[index])
        trace("request=\(request.id) posted phase=\(Self.phaseName(strafe_event_gesture_phase(events[index]))) uptime=\(ProcessInfo.processInfo.systemUptime)")
        if index + 1 < events.count {
            queue.asyncAfter(deadline: .now() + activeGapMS / 1000) {
                self.postPhase(index + 1)
            }
        } else {
            deadline = ProcessInfo.processInfo.systemUptime + 0.750
            poll()
        }
    }

    private static func phaseName(_ phase: Int64) -> String {
        switch phase {
        case strafe_gesture_phase_began(): return "Began"
        case strafe_gesture_phase_changed(): return "Changed"
        case strafe_gesture_phase_ended(): return "Ended"
        case strafe_gesture_phase_cancelled(): return "Cancelled"
        default: return "phase\(phase)"
        }
    }

    /// A single odd topology read proves nothing: Mission Control's close
    /// animation can leave CGS mid-flight for a poll or two. Only consecutive
    /// anomalies fail the request; any clean read resets the count.
    private func anomalous(_ request: Request, _ message: String, live: Topology) {
        anomalies += 1
        guard anomalies >= 2 else {
            trace("request=\(request.id) transient \(message) live={\(live.summary)}")
            queue.asyncAfter(deadline: .now() + 0.025) { self.poll() }
            return
        }
        trace("request=\(request.id) \(message) live={\(live.summary)}")
        finish(.failure(.unexpectedChange), dropPending: true)
    }

    private func poll() {
        guard let request = active, let origin else { return }
        guard !overlayUp() else {
            finish(.failure(.overlayActive), dropPending: true)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard let live = dependencies.read(origin.display) else {
            trace("request=\(request.id) observation live=unavailable")
            finish(.failure(.topologyUnavailable), dropPending: true)
            return
        }
        if now >= deadline {
            trace("request=\(request.id) timeout live={\(live.summary)} target=\(target)")
            finish(.failure(.observationTimedOut), dropPending: true)
            return
        }
        guard live.count == origin.count,
              (live.index == origin.index && live.id == origin.id) ||
                (live.index == target && live.id != origin.id) else {
            anomalous(request, "unexpected transition", live: live)
            return
        }
        if live.index == target {
            if let candidateID, candidateID != live.id {
                anomalous(request, "target ID changed", live: live)
                return
            }
            if candidateID == nil { candidateID = live.id; candidateSince = now }
            // Stable destination plus settle time reduces races with the next
            // request. This is not a measurement of destination input unlock.
            if now - candidateSince >= 0.100 {
                trace("request=\(request.id) observed transition live={\(live.summary)} inputUnlock=unverified")
                finish(.success(()))
                return
            }
        } else if candidateID != nil {
            anomalous(request, "transition reverted", live: live)
            return
        }
        anomalies = 0
        queue.asyncAfter(deadline: .now() + 0.025) { self.poll() }
    }

    private func complete(_ request: Request, _ result: Result<Void, SwitchEngineError>) {
        admission.lock()
        admitted -= 1
        admission.unlock()
        if case .failure(let error) = result {
            SwitchDiagnostics.log("request=\(request.id) direction=\(request.direction) failed: \(error)")
            switch error {
            case .unexpectedChange, .observationTimedOut, .postFailed, .topologyUnavailable:
                // Grace period: an overlay was up within the last second, so
                // this failure likely describes Mission Control's close
                // animation settling — not a broken replacement path. Never
                // disable interception over that.
                if error == .unexpectedChange || error == .observationTimedOut,
                   ProcessInfo.processInfo.systemUptime - lastOverlaySeen < 1.0 {
                    SwitchDiagnostics.log("request=\(request.id) failure callback suppressed (recent overlay)")
                } else {
                    deliveryFailureHandler?(error)
                }
            default: break
            }
        }
        request.completion?(result)
    }

    private func finish(_ result: Result<Void, SwitchEngineError>, dropPending: Bool = false) {
        guard let request = active else { return }
        active = nil
        events.removeAll()
        origin = nil
        candidateID = nil
        if dropPending {
            admission.lock()
            generation &+= 1
            admission.unlock()
            let dropped = pending
            pending.removeAll()
            for request in dropped { complete(request, .failure(.pendingDropped)) }
        }
        complete(request, result)
        queue.async { self.startNext() }
    }
}
