import AppKit

/// The menu-bar controller. Owns the `NSStatusItem` and wires its menu to the
/// interceptor / permission state. LSUIElement is set in the bundled
/// Info.plist so there is no dock icon.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let interceptor: SwipeInterceptor
    private let engine: GestureSwitchEngine?
    private let hotkeys: HotkeyManager?

    private let toggleItem = NSMenuItem(
        title: "Enable", action: #selector(toggleEnabled), keyEquivalent: ""
    )
    private let speedItem = NSMenuItem(
        title: "Transition speed", action: nil, keyEquivalent: ""
    )
    private var speedItems: [NSMenuItem] = []
    private let hotkeysItem = NSMenuItem(
        title: "Space-switch hotkeys (⌃⌥←/→)", action: #selector(toggleHotkeys), keyEquivalent: ""
    )
    private let accessibilityItem = NSMenuItem(
        title: "Accessibility granted: —", action: nil, keyEquivalent: ""
    )

    /// Shipped version, read from the bundle so `VERSION` stays the single
    /// source of truth (`Scripts/bundle.sh` stamps it into Info.plist). A bare
    /// `swift build` binary has no Info.plist, and "dev" is the honest answer
    /// there — it genuinely isn't a released build.
    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    init(interceptor: SwipeInterceptor, engine: GestureSwitchEngine? = nil, hotkeys: HotkeyManager? = nil) {
        self.interceptor = interceptor
        self.engine = engine
        self.hotkeys = hotkeys
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        // AppKit restores the previous visibility; every new launch starts visible.
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.on.rectangle",
                accessibilityDescription: "strafe"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self

        toggleItem.target = self
        accessibilityItem.isEnabled = false

        engine?.setTransitionSpeed(TransitionSpeed.stored)

        menu.addItem(toggleItem)
        buildSpeedSubmenu(into: menu)
        if hotkeys != nil {
            hotkeysItem.target = self
            menu.addItem(hotkeysItem)
        }
        menu.addItem(accessibilityItem)

        // Update story, stated rather than performed. strafe cannot reach the
        // internet, so it cannot check for a new version; instead of a
        // check-for-updates button that would need that ability, the menu just
        // says what's running and where newer builds live. Both items are inert
        // text — nothing is opened, copied, or fetched. Keeping them inert is
        // what lets the greps in SECURITY.md keep returning zero hits, so
        // resist the urge to make this line clickable.
        menu.addItem(.separator())
        for line in ["strafe \(Self.version)",
                     "No auto-update — github.com/rileycx/strafe"] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let hide = NSMenuItem(
            title: "Hide from menu bar", action: #selector(hideFromMenuBar), keyEquivalent: ""
        )
        hide.target = self
        menu.addItem(hide)
        let quit = NSMenuItem(title: "Quit strafe", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        refresh()
    }

    // Show the icon again. Called when the app is reopened while it is already running.
    func show() {
        statusItem.isVisible = true
    }

    /// The "Transition speed" submenu: one checkable item per preset.
    ///
    /// Hidden entirely when there is no real engine (stub engine / no
    /// Accessibility), because nothing it offers would take effect.
    private func buildSpeedSubmenu(into menu: NSMenu) {
        guard engine != nil else { return }

        let submenu = NSMenu()
        for speed in TransitionSpeed.allCases {
            let item = NSMenuItem(
                title: speed.title, action: #selector(selectSpeed(_:)), keyEquivalent: ""
            )
            item.target = self
            item.tag = speed.rawValue
            submenu.addItem(item)
            speedItems.append(item)
        }

        speedItem.submenu = submenu
        menu.addItem(speedItem)
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        // Toggle interception. The tap stays alive (so it can re-enable itself
        // after a system auto-disable); `overrideEnabled` gates whether real
        // swipes are actually suppressed and replaced (SPEC §2.2).
        interceptor.overrideEnabled.toggle()
        if interceptor.overrideEnabled && !interceptor.isRunning {
            interceptor.start()
        }
        refresh()
    }

    /// Pick a transition speed. Persisted so the choice survives a relaunch.
    @objc private func selectSpeed(_ sender: NSMenuItem) {
        let speed = TransitionSpeed.from(rawValue: sender.tag)
        engine?.setTransitionSpeed(speed)
        speed.persist()
        refresh()
    }

    /// Toggle the Ctrl+Option+Left/Right global hotkeys, independent of the
    /// gesture tap (`toggleEnabled`). This is the mechanism that can conflict
    /// with third-party window-tiling shortcuts bound to the same chord.
    @objc private func toggleHotkeys() {
        guard let hotkeys else { return }
        let newValue = !HotkeyManager.enabled
        HotkeyManager.persist(enabled: newValue)
        hotkeys.applyStoredState()
        refresh()
    }

    // AppKit saves visibility; initialization resets it on the next launch.
    @objc private func hideFromMenuBar() {
        let alert = NSAlert()
        alert.messageText = "Hide strafe from the menu bar?"
        alert.informativeText = """
            strafe stays running in the background. Swipes and keyboard \
            shortcuts keep working.

            To bring the icon back or to quit, open strafe again from \
            Applications or Spotlight.
            """
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        // An accessory app is never frontmost, so bring the alert forward.
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        statusItem.isVisible = false
    }

    @objc private func quit() {
        interceptor.teardown()
        NSApp.terminate(nil)
    }

    // MARK: - State

    private func refresh() {
        toggleItem.title = interceptor.overrideEnabled ? "Disable" : "Enable"
        if let engine {
            let current = engine.transitionSpeed
            speedItem.title = "Transition speed: \(current.title)"
            for item in speedItems { item.state = item.tag == current.rawValue ? .on : .off }
        }
        accessibilityItem.title = interceptor.statusDescription
        hotkeysItem.state = HotkeyManager.enabled ? .on : .off
    }
}
