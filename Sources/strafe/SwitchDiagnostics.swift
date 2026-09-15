import Foundation

/// Writes happen on a dedicated queue, never in an event-tap callback.
enum SwitchDiagnostics {
    private static let queue = DispatchQueue(label: "strafe.diagnostics")

    static func log(_ message: String) {
        queue.async {
            FileHandle.standardError.write(Data("[strafe] \(message)\n".utf8))
        }
    }

    /// CLI calls this before exiting so the last observation/error is retained.
    static func flush() { queue.sync {} }
}

struct SwitchConfiguration: Sendable {
    let profile: String
    let augmented: Bool
    let phaseGapMS: Double
    let inverted: Bool
    let invertSwipeDirection: Bool
    let interceptSwipes: Bool
    let diagnostics: Bool

    struct Invalid: Error, CustomStringConvertible {
        let description: String
    }

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    ) throws -> SwitchConfiguration {
        let profile = environment["STRAFE_EVENT_PROFILE"] ?? "auto"
        guard ["auto", "legacy", "macos27"].contains(profile) else {
            throw Invalid(description: "STRAFE_EVENT_PROFILE must be auto|legacy|macos27; got '\(profile)'")
        }
        let augmented = profile == "macos27" || (profile == "auto" && osMajorVersion >= 27)
        var gap = augmented ? 10.0 : 0.0
        if let raw = environment["STRAFE_PHASE_GAP_MS"] {
            guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  let value = Double(raw), value.isFinite, (0...100).contains(value) else {
                throw Invalid(description: "STRAFE_PHASE_GAP_MS must be a finite decimal in 0...100; got '\(raw)'")
            }
            gap = value
        }
        func flag(_ name: String, default fallback: Bool = false) throws -> Bool {
            guard let raw = environment[name] else { return fallback }
            guard raw == "0" || raw == "1" else {
                throw Invalid(description: "\(name) must be 0|1; got '\(raw)'")
            }
            return raw == "1"
        }
        return try SwitchConfiguration(
            profile: profile, augmented: augmented, phaseGapMS: gap,
            inverted: flag("STRAFE_INVERT_DIRECTION", default: augmented),
            invertSwipeDirection: flag("STRAFE_INVERT_SWIPE_DIRECTION", default: osMajorVersion >= 27),
            interceptSwipes: flag("STRAFE_INTERCEPT_SWIPES", default: true),
            diagnostics: flag("STRAFE_DIAGNOSTICS")
        )
    }

    var summary: String {
        "profile=\(profile) resolved=\(augmented ? "macos27" : "legacy") augmented=\(augmented) phaseGapMS=\(phaseGapMS) inverted=\(inverted) invertSwipeDirection=\(invertSwipeDirection) interceptSwipes=\(interceptSwipes) diagnostics=\(diagnostics) prediction=disabled queueLimit=16 observationMS=750 settleMS=100"
    }
}
