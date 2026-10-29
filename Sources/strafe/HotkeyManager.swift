import Foundation

/// Owns the optional Control-arrow interceptor and synchronizes its preference.
@MainActor
final class HotkeyManager {
    private let controlArrows: ControlArrowInterceptor

    var controlArrowsRunning: Bool { controlArrows.isRunning }

    private var settingsObserver: (any NSObjectProtocol)?

    nonisolated private static let settingsChanged = Notification.Name(
        "com.rileycx.strafe.hotkeysChanged"
    )

    init(engine: SwitchEngine) {
        self.controlArrows = ControlArrowInterceptor(engine: engine)
    }

    func start() {
        guard settingsObserver == nil else { return }
        settingsObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.settingsChanged, object: Preferences.domain, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settingsObserver != nil else { return }
                self.applyStoredState()
            }
        }
        applyStoredState()
    }

    func stop() {
        if let settingsObserver {
            DistributedNotificationCenter.default().removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        controlArrows.stop()
    }

    /// Apply the shared preference. Native macOS shortcuts are only paused in
    /// memory, while Control is held.
    func applyStoredState() {
        // Refresh the cache after another process changes the shared preference.
        Preferences.store.synchronize()
        if Self.controlArrowsEnabled { controlArrows.start() } else { controlArrows.stop() }
    }

    // MARK: - Persistence

    nonisolated static let controlArrowsStorageKey = "controlArrowHotkeysEnabled"

    /// Enabled on first launch; an explicitly saved false remains off.
    /// Native macOS shortcuts remain enabled.
    nonisolated static var controlArrowsEnabled: Bool {
        Preferences.store.object(forKey: controlArrowsStorageKey) as? Bool ?? true
    }

    nonisolated static let controlArrowSetup = """
        Keep macOS “Move left a space” and “Move right a space” enabled.

        While strafe runs, Control+Left/Right uses your chosen transition speed. \
        No Option, Command, or Shift key is needed. While Control is held, strafe \
        pauses those two macOS shortcuts in memory; they return when you release \
        Control, quit strafe, or turn this option off. Your saved shortcut settings \
        are never edited.

        This option adds a modifier-key event tap. It sees Control, Shift, Command, \
        Option and Fn changes only, never letters, numbers or other keys. \
        Accessibility permission is required.
        """

    nonisolated static func persist(controlArrowsEnabled: Bool) {
        Preferences.store.set(controlArrowsEnabled, forKey: controlArrowsStorageKey)
        notifySettingsChanged()
    }

    nonisolated private static func notifySettingsChanged() {
        // Flush before notifying so a resident app cannot read the previous value.
        Preferences.store.synchronize()
        DistributedNotificationCenter.default().postNotificationName(
            settingsChanged, object: Preferences.domain, userInfo: nil, deliverImmediately: true
        )
    }

}
