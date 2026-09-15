import AppKit
import CStrafe

// MARK: - Entry point
//
// With CLI args -> headless mode (call the engine directly, print, exit).
// With no args  -> start the menu-bar NSApplication.

/// The engine seam. `GestureSwitchEngine` posts real synthetic dock-swipe
/// gestures (SPEC §1). `StubSwitchEngine` remains available for tests / dry runs.
let engine: GestureSwitchEngine
let configuration: SwitchConfiguration
do {
    configuration = try SwitchConfiguration.load()
    engine = GestureSwitchEngine(configuration: configuration)
} catch {
    SwitchDiagnostics.log("configuration error: \(error)")
    SwitchDiagnostics.flush()
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty {
    runMenuBarApp(engine: engine)
} else {
    let status = runCLI(args, engine: engine)
    SwitchDiagnostics.flush()
    exit(status)
}

// MARK: - CLI mode

/// The engine completes on its serial queue while the CLI pumps the main loop.
final class CLISwitchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, SwitchEngineError>?

    func store(_ result: Result<Void, SwitchEngineError>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<Void, SwitchEngineError>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

func runCLI(_ args: [String], engine: GestureSwitchEngine) -> Int32 {
    switch args.first {
    case "switch":
        guard args.count == 2 else {
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
            MissionControlMonitor.shared.start()
            defer { MissionControlMonitor.shared.stop() }
            let completion = CLISwitchResult()
            try engine.switchSpace(direction) { completion.store($0) }
            // Covers ramp schedules (60 ms), 750 ms observation, and
            // scheduling slack. Never exit merely on enqueue: `CGEventPost`
            // hands the gesture to the WindowServer asynchronously, and an
            // exit that close behind the post loses it. The menu-bar app never
            // hits this because it stays alive.
            let deadline = ProcessInfo.processInfo.systemUptime + 2.0
            // A timer supplies a run-loop source even in this headless process.
            let timer = Timer(timeInterval: 0.01, repeats: true) { _ in }
            RunLoop.current.add(timer, forMode: .default)
            defer { timer.invalidate() }
            while completion.load() == nil && ProcessInfo.processInfo.systemUptime < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
            }
            guard let result = completion.load() else {
                SwitchDiagnostics.log("switch failed: CLI completion deadline exceeded (2 seconds)")
                return 1
            }
            switch result {
            case .success: return 0
            case .failure(let error):
                SwitchDiagnostics.log("switch failed: \(error)")
                return 1
            }
        } catch {
            SwitchDiagnostics.log("switch failed: \(error)")
            return 1
        }

    case "status":
        MissionControlMonitor.shared.start()
        defer { MissionControlMonitor.shared.stop() }
        // No live tap in CLI mode, so report tap as not running. CGS symbol
        // resolution is the capability check per SPEC §1.1 / §6.
        Permissions.printStatus(tapRunning: false, cgsAvailable: engine.cgsAvailable)
        print("  Live topology:         \(engine.topologyStatus)")
        print("  Overlay active:        \(MissionControlMonitor.shared.isActive)")
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

    case "mc-probe":
        // Overlay-detection diagnostic: reports what Mission Control looks
        // like to strafe while you open and close it. AX notifications (if
        // Dock still posts them) log as they arrive; the layer histogram
        // shows what the snapshot heuristic sees. Private overlay behavior
        // changes between macOS versions, so re-probe there before trusting
        // these numbers anywhere else.
        let seconds: Double
        if args.count >= 2, let value = Double(args[1]), value > 0, value <= 120 {
            seconds = value
        } else if args.count >= 2 {
            FileHandle.standardError.write(Data("usage: strafe mc-probe [seconds 1-120]\n".utf8))
            return 2
        } else {
            seconds = 15
        }
        MissionControlMonitor.shared.start()
        defer { MissionControlMonitor.shared.stop() }
        print("mc-probe: open and close Mission Control within \(Int(seconds))s")
        let end = ProcessInfo.processInfo.systemUptime + seconds
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
            var dock = Int32(0), layer18 = Int32(0), layer20 = Int32(0)
            strafe_expose_counts(&dock, &layer18, &layer20)
            print("mc-probe ax=\(MissionControlMonitor.shared.isActive) " +
                "snapshot=\(strafe_is_expose_active()) " +
                "dock=\(dock) layer18=\(layer18) layer20=\(layer20)")
        }
        RunLoop.current.add(timer, forMode: .default)
        defer { timer.invalidate() }
        while ProcessInfo.processInfo.systemUptime < end {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        return 0

    default:
        FileHandle.standardError.write(Data("""
        strafe — near-instant macOS Spaces switching

        usage:
          strafe                      start the menu-bar app
          strafe switch left|right    switch space once and exit
          strafe status               print accessibility / tap status
          strafe speed [preset]       show or set the swipe transition speed
          strafe mc-probe [seconds]   sample overlay detection for diagnosis

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
    withExtendedLifetime(delegate) { app.run() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine: GestureSwitchEngine
    private var interceptor: SwipeInterceptor!
    private var hotkeys: HotkeyManager!
    private var statusItem: StatusItemController!
    private var spaceObserver: (any NSObjectProtocol)?

    init(engine: GestureSwitchEngine) {
        self.engine = engine
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompt for accessibility up front so the tap can be created.
        Permissions.checkAccessibility(prompt: true)

        MissionControlMonitor.shared.start()
        interceptor = SwipeInterceptor(engine: engine, configuration: configuration)
        engine.setDeliveryFailureHandler { [weak interceptor] error in
            DispatchQueue.main.async {
                guard let interceptor, interceptor.overrideEnabled else { return }
                interceptor.overrideEnabled = false
                SwitchDiagnostics.log("trackpad interception paused after \(error); native swipes restored. Re-enable from the menu after diagnosis.")
            }
        }
        statusItem = StatusItemController(interceptor: interceptor, engine: engine)

        hotkeys = HotkeyManager(engine: engine)
        hotkeys.register()

        // Compatibility notification seam: live polling now reconciles state;
        // this notification must not cancel the switch it is reporting.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [engine] _ in
            engine.resetPredictions()
        }

        interceptor.start()
        SwitchDiagnostics.log("app ready accessibility=\(Permissions.isAccessibilityGranted) tapEnabled=\(interceptor.isRunning)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        interceptor?.teardown()
        hotkeys?.unregister()
        MissionControlMonitor.shared.stop()
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil
    }
}
