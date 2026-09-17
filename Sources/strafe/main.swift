import AppKit

// MARK: - Entry point
//
// With CLI args -> headless mode (call the engine directly, print, exit).
// With no args  -> start the menu-bar NSApplication.

/// The engine seam. `GestureSwitchEngine` posts real synthetic dock-swipe
/// gestures (SPEC §1). `StubSwitchEngine` remains available for tests / dry runs.
let engine = GestureSwitchEngine()

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty {
    runMenuBarApp(engine: engine)
} else {
    exit(runCLI(args, engine: engine))
}

// MARK: - CLI mode

func runCLI(_ args: [String], engine: GestureSwitchEngine) -> Int32 {
    switch args.first {
    case "switch":
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: strafe switch left|right\n".utf8))
            return 2
        }
        let direction: SwitchDirection
        switch args[1] {
        case "left": direction = .left
        case "right": direction = .right
        default:
            FileHandle.standardError.write(Data("unknown direction '\(args[1])' (expected left|right)\n".utf8))
            return 2
        }
        // Honor the persisted transition speed, same as the menu-bar app, so
        // `strafe switch` and a real swipe look identical.
        engine.setTransitionSpeed(TransitionSpeed.stored)
        do {
            try engine.switchSpace(direction)
            // A ramped switch posts asynchronously; returning here exits the
            // process, so drain it first or the gesture never finishes.
            engine.waitForPendingSwitch()
            // `CGEventPost` hands the event to the WindowServer asynchronously.
            // Returning here exits immediately, and an exit that close behind the
            // post loses the gesture — measured: without this pause `strafe
            // switch` posts successfully and nothing moves. The menu-bar app
            // never hits this because it stays alive.
            usleep(120_000)
            return 0
        } catch {
            FileHandle.standardError.write(Data("switch failed: \(error)\n".utf8))
            return 1
        }

    case "status":
        // No live tap in CLI mode, so report tap as not running. CGS symbol
        // resolution is the capability check per SPEC §1.1 / §6.
        Permissions.printStatus(tapRunning: false, cgsAvailable: engine.cgsAvailable)
        return 0

    case "speed":
        // Same setting the menu-bar "Transition speed" submenu writes; a running
        // menu-bar app won't notice until relaunch.
        guard args.count >= 2 else {
            let current = TransitionSpeed.stored
            print("transition speed: \(current.title)")
            let width = TransitionSpeed.allCases.map(\.name.count).max() ?? 0
            for speed in TransitionSpeed.allCases {
                let mark = speed == current ? "*" : " "
                let pad = String(repeating: " ", count: width - speed.name.count)
                print("  \(mark) \(speed.name)\(pad)  \(speed.title)")
            }
            return 0
        }
        guard let speed = TransitionSpeed(name: args[1]) else {
            let names = TransitionSpeed.allCases.map(\.name).joined(separator: "|")
            FileHandle.standardError.write(Data(
                "unknown speed '\(args[1])' (expected \(names))\n".utf8))
            return 2
        }
        speed.persist()
        print("transition speed: \(speed.title)")
        return 0

    default:
        FileHandle.standardError.write(Data("""
        strafe — near-instant macOS Spaces switching

        usage:
          strafe                      start the menu-bar app
          strafe switch left|right    switch space once and exit
          strafe status               print accessibility / tap status
          strafe speed [preset]       show or set the swipe transition speed

        """.utf8))
        return 2
    }
}

// MARK: - Menu-bar app mode

@MainActor
func runMenuBarApp(engine: GestureSwitchEngine) {
    let app = NSApplication.shared
    // LSUIElement is also set in Info.plist; set it here so running the raw
    // binary (unbundled) still behaves as an accessory with no dock icon.
    app.setActivationPolicy(.accessory)

    let delegate = AppDelegate(engine: engine)
    app.delegate = delegate
    app.run()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine: GestureSwitchEngine
    private var interceptor: SwipeInterceptor!
    private var hotkeys: HotkeyManager!
    private var statusItem: StatusItemController!

    init(engine: GestureSwitchEngine) {
        self.engine = engine
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompt for accessibility up front so the tap can be created.
        Permissions.checkAccessibility(prompt: true)

        interceptor = SwipeInterceptor(engine: engine)
        statusItem = StatusItemController(interceptor: interceptor, engine: engine)

        hotkeys = HotkeyManager(engine: engine)
        hotkeys.register()

        // SPEC §2.4 / §5: reset the prediction dictionary to live CGS data
        // whenever the OS reports a real space change, so rapid repeated swipes
        // don't overshoot bounds or snap back off a stale predicted index.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [engine] _ in
            engine.resetPredictions()
        }

        interceptor.start()
    }

    /// Launch Services sends this when the app is opened while already
    /// running. It is the way back from "Hide from menu bar": there is no
    /// window and no icon, so opening the app again is the only handle left.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        statusItem?.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        interceptor?.teardown()
        hotkeys?.unregister()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
