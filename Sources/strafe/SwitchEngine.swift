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

    private func trace(_ message: String) {
        if configuration.diagnostics { SwitchDiagnostics.log(message) }
    }

    private func startNext() {
        guard active == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        active = request
        guard !dependencies.overlayActive() else {
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
        trace("request=\(request.id) direction=\(request.direction) live={\(live.summary)} predicted=none target=\(atEdge ? "edge" : String(request.direction == .left ? live.index - 1 : live.index + 1))")
        guard !atEdge else { finish(.failure(.atEdge)); return }
        target = request.direction == .left ? live.index - 1 : live.index + 1
        // Allocate the whole sequence before posting Began. A builder failure
        // must not strand Dock with a partially constructed gesture.
        for phase in [strafe_gesture_phase_began(), strafe_gesture_phase_changed(), strafe_gesture_phase_ended()] {
            guard let event = dependencies.build(request.direction, velocity, phase,
                                                 configuration.augmented, configuration.inverted) else {
                finish(.failure(.postFailed), dropPending: true)
                return
            }
            events.append(event)
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
        if dependencies.overlayActive() {
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
        trace("request=\(request.id) posted phase=\(["Began", "Changed", "Ended"][index]) uptime=\(ProcessInfo.processInfo.systemUptime)")
        if index < 2 {
            queue.asyncAfter(deadline: .now() + configuration.phaseGapMS / 1000) {
                self.postPhase(index + 1)
            }
        } else {
            deadline = ProcessInfo.processInfo.systemUptime + 0.750
            poll()
        }
    }

    private func poll() {
        guard let request = active, let origin else { return }
        guard !dependencies.overlayActive() else {
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
            trace("request=\(request.id) unexpected transition live={\(live.summary)}")
            finish(.failure(.unexpectedChange), dropPending: true)
            return
        }
        if live.index == target {
            if let candidateID, candidateID != live.id {
                trace("request=\(request.id) target ID changed live={\(live.summary)}")
                finish(.failure(.unexpectedChange), dropPending: true)
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
            trace("request=\(request.id) transition reverted live={\(live.summary)}")
            finish(.failure(.unexpectedChange), dropPending: true)
            return
        }
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
                deliveryFailureHandler?(error)
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
