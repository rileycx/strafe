import AppKit

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
        do {
            MissionControlMonitor.shared.start()
            defer { MissionControlMonitor.shared.stop() }
            let completion = CLISwitchResult()
            try engine.switchSpace(direction) { completion.store($0) }
            // Covers the maximum configured phase gaps (200 ms), 750 ms
            // observation, and scheduling slack. Never exit merely on enqueue.
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

    default:
        FileHandle.standardError.write(Data("""
        strafe — near-instant macOS Spaces switching

        usage:
          strafe                      start the menu-bar app
          strafe switch left|right    switch space once and exit
          strafe status               print accessibility / tap status

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
        statusItem = StatusItemController(interceptor: interceptor)

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
