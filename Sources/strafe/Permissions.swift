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
    /// The CLI process has no tap, so it must not report its own state as if it
    /// described the separately running menu-bar app. `cgsAvailable` reports
    /// whether the private CGS topology symbols resolved.
    static func printStatus(cgsAvailable: Bool) {
        let ax = isAccessibilityGranted ? "yes" : "no"
        let cgs = cgsAvailable ? "yes" : "no"
        print("strafe status")
        print("  Accessibility granted: \(ax)")
        print("  Event tap:             see menu (CLI creates no tap)")
        print("  CGS symbols resolved:  \(cgs)")
        print("  Transition speed:      \(TransitionSpeed.stored.title)")
    }
}
