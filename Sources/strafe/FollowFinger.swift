import CStrafe
import Foundation

/// "Follow finger" swipe mode.
///
/// The default mode suppresses the real swipe and posts an instant synthetic
/// one, which removes the input delay but also the finger-tracking slide. This
/// mode lets the real gesture through untouched, so the Space tracks your
/// fingers and can be dragged back, and changes only its release: the `ended`
/// event's velocity is raised toward the Space the slide should settle on. The
/// slide keeps its momentum but settles sooner, and the queued input that
/// follows a native swipe is mostly that settle animation.
enum FollowFinger {
    static let enabledKey = "followFinger"

    /// Off by default, so strafe's out-of-the-box behaviour is unchanged.
    static var enabled: Bool { Preferences.store.bool(forKey: enabledKey) }

    static func persist(enabled: Bool) {
        Preferences.store.set(enabled, forKey: enabledKey)
    }

    /// The release speed for the next swipe, or nil when the mode is off.
    static var activeReleaseSpeed: ReleaseSpeed? { enabled ? ReleaseSpeed.stored : nil }

    /// Which way a released slide should settle: +1 toward the Space on the
    /// right, -1 toward the left, nil when the gesture never moved. Positive
    /// progress/velocity means rightward, as for `strafe_event_moves_right`.
    ///
    /// Mirrors how a native swipe feels: a flick (real releases measure about
    /// 2–8; a held finger about 0–0.3) settles the way it was moving, so a
    /// short flick switches and a flick back cancels; a slow release switches
    /// past halfway and otherwise snaps back.
    static func settleDirection(progress: Double, velocity: Double) -> Double? {
        guard progress != 0 else { return nil }
        if abs(velocity) >= 0.5 { return velocity > 0 ? 1 : -1 }
        let towardProgress: Double = progress > 0 ? 1 : -1
        return abs(progress) >= 0.5 ? towardProgress : -towardProgress
    }

    /// Whether the display under the cursor has a Space in that direction, or
    /// nil if topology cannot be read.
    static func liveNeighborExists(right: Bool) -> Bool? {
        var info = StrafeInfo()
        guard strafe_get_space_info(&info) else { return nil }
        return right ? info.currentIndex + 1 < info.spaceCount : info.currentIndex > 0
    }
}

/// One real swipe in follow-finger mode, from `began` to its release.
struct FollowedSwipe {
    let speed: ReleaseSpeed
    private var lastProgress = 0.0
    private var lastVelocity = 0.0

    init(speed: ReleaseSpeed) { self.speed = speed }

    /// Record a `changed` event, for a release that reports no motion itself.
    mutating func track(progress: Double, velocity: Double) {
        if progress != 0 { lastProgress = progress }
        lastVelocity = velocity
    }

    /// The velocity to write into the `ended` event, or nil to leave it alone:
    /// when the gesture never moved, or when it would settle on a Space that
    /// does not exist (macOS then runs its own rubber-band).
    func releaseVelocity(progress: Double, velocity: Double,
                         neighborExists: (_ right: Bool) -> Bool?) -> Double? {
        let progress = progress != 0 ? progress : lastProgress
        let velocity = velocity != 0 ? velocity : lastVelocity
        guard let direction = FollowFinger.settleDirection(progress: progress, velocity: velocity)
        else { return nil }
        let switching = (direction > 0) == (progress > 0)
        if switching, neighborExists(direction > 0) == false { return nil }
        return direction * speed.velocity
    }
}

/// How quickly a follow-finger swipe settles after you lift your fingers.
///
/// Unlike `TransitionSpeed`, these are not measured durations: the Dock's
/// settle time is not linear in release velocity (synthetic flicks below ~80
/// animate, above it they jump), so the presets are spaced between a real
/// release (about 2–8) and that cliff, plus the jump. 130 already felt like a
/// snap in testing.
enum ReleaseSpeed: Int, CaseIterable {
    case gentle = 0
    case smooth = 1
    case quick = 2
    case instant = 3

    static let `default`: ReleaseSpeed = .smooth

    /// Release velocity written into the `ended` event, in the event's units.
    var velocity: Double {
        switch self {
        case .gentle:  return 10
        case .smooth:  return 20
        case .quick:   return 40
        case .instant: return 2000
        }
    }

    var title: String {
        switch self {
        case .gentle:  return "Gentle"
        case .smooth:  return "Smooth"
        case .quick:   return "Quick"
        case .instant: return "Instant (no slide)"
        }
    }

    /// Stable identifier for `strafe release <name>`.
    var name: String { String(describing: self) }

    init?(name: String) {
        guard let match = ReleaseSpeed.allCases.first(where: { $0.name == name }) else { return nil }
        self = match
    }

    // MARK: - Persistence

    static let storageKey = "releaseSpeed"

    static var stored: ReleaseSpeed {
        guard let raw = Preferences.store.object(forKey: storageKey) as? Int else { return .default }
        return ReleaseSpeed(rawValue: raw) ?? .default
    }

    func persist() {
        Preferences.store.set(rawValue, forKey: ReleaseSpeed.storageKey)
    }
}
