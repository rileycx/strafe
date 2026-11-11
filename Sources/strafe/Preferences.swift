import Foundation

/// The one preferences store every strafe setting reads and writes.
///
/// WHY THIS EXISTS RATHER THAN `UserDefaults.standard`: `.standard` resolves its
/// domain from the running process's bundle identifier. strafe ships as a single
/// binary that runs two ways — inside `strafe.app` (bundle id
/// `com.rileycx.strafe`) and as a bare CLI (`strafe speed quick`), which has no
/// Info.plist and therefore no bundle id at all. `.standard` silently uses two
/// different domains for those two cases:
///
///     ~/Library/Preferences/com.rileycx.strafe.plist   <- the menu-bar app
///     ~/Library/Preferences/strafe.plist               <- the CLI
///
/// so the CLI would report the setting it just wrote while the running app went
/// on reading a stale value out of a different file forever. Measured, not
/// theorized: it is what made an earlier CLI toggle look like a no-op.
///
/// Naming the suite explicitly pins both launch modes to the app's domain.
enum Preferences {
    /// The app's bundle identifier, matching `BUNDLE_ID` in Scripts/bundle.sh.
    /// Changing one without the other silently orphans every stored setting.
    static let domain = "com.rileycx.strafe"

    /// `nonisolated(unsafe)` because `UserDefaults` is not `Sendable` but *is*
    /// documented thread-safe — the same reason `UserDefaults.standard` itself
    /// is usable from any thread. The menu (main actor) and the CLI are the only
    /// writers, and they never run in the same process at the same time.
    nonisolated(unsafe) static let store: UserDefaults = {
        // Inside strafe.app the bundle identifier already *is* `domain`, so
        // `.standard` resolves there anyway — and asking for a suite named after
        // your own bundle id is a no-op AppKit logs a warning about. Only the
        // bundle-less CLI needs to name the domain explicitly.
        if Bundle.main.bundleIdentifier == domain { return .standard }
        return UserDefaults(suiteName: domain) ?? .standard
    }()
}

/// A setting that is one of a fixed list of presets, stored as its raw value.
/// The menu, the settings window, and the CLI all read and write it through
/// here, so they cannot drift apart on either the key or the fallback.
protocol StoredPreset: CaseIterable, Equatable, RawRepresentable where RawValue == Int {
    /// The one `UserDefaults` key this setting uses.
    static var storageKey: String { get }
    static var `default`: Self { get }
    /// Shown in the menu and the settings window.
    var title: String { get }
    /// Stable identifier for the CLI.
    var name: String { get }
}

extension StoredPreset {
    init?(name: String) {
        guard let match = Self.allCases.first(where: { $0.name == name }) else { return nil }
        self = match
    }

    /// The persisted preset. An absent key (a fresh install) or a raw value
    /// that is no longer a preset means `default`. `object(forKey:)` rather
    /// than `integer(forKey:)` so "never set" is distinguishable from a stored 0.
    static var stored: Self {
        (Preferences.store.object(forKey: storageKey) as? Int).flatMap(Self.init(rawValue:)) ?? .default
    }

    func persist() {
        Preferences.store.set(rawValue, forKey: Self.storageKey)
    }
}
