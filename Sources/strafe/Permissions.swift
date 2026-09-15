import ApplicationServices
import Foundation

/// Accessibility permission helpers plus the `strafe status` readout.
enum Permissions {
    /// Whether this process is currently trusted for the Accessibility API.
    /// Never prompts.
    static var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Check trust, optionally showing the system prompt that deep-links the
    /// user into System Settings › Privacy & Security › Accessibility.
    /// Returns the current trust state (which will be `false` on first prompt).
    @discardableResult
    static func checkAccessibility(prompt: Bool) -> Bool {
        // `kAXTrustedCheckOptionPrompt` is a non-Sendable global under Swift 6
        // strict concurrency, so use its documented string value directly.
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Print a human-readable status readout for `strafe status`.
    /// `tapRunning` is supplied by the caller since tap state lives on the
    /// interceptor instance. `cgsAvailable` reports whether the private CGS
    /// topology symbols resolved (SPEC §1.1 capability check).
    static func printStatus(tapRunning: Bool, cgsAvailable: Bool) {
        let ax = isAccessibilityGranted ? "yes" : "no"
        let tap = tapRunning ? "yes" : "no"
        let cgs = cgsAvailable ? "yes" : "no"
        print("strafe status")
        print("  Accessibility granted: \(ax)")
        print("  Event tap running:     \(tap) (this process only; not resident-app status)")
        print("  CGS symbols resolved:  \(cgs)")
        print("  Transition speed:      \(TransitionSpeed.stored.title)")
    }
}
