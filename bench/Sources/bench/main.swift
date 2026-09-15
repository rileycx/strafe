import AppKit
import Foundation

// bench — time-to-interactivity measurement + demo-window tooling for strafe.
//
// This is a DEV / MEASUREMENT tool, deliberately separate from the strafe app
// that SECURITY.md audits. It reuses strafe's CStrafe synthesis code path (via
// the `.package(path: "..")` dependency) so the "strafe" numbers exercise the
// exact same gesture poster the shipped app calls.
//
// Subcommands:
//   bench windows                        demo-window mode for video takes
//   bench run --mode native|strafe [--trials N]   the measurement
//   bench specs                          print the redacted machine-info block
//
// NOTE: gesture/click posting requires Accessibility. Run the bundled bench.app
// (see bundle-bench.sh) so the grant attributes to bench, not your terminal.

@MainActor
func parseFlag(_ args: [String], _ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

@MainActor
func runWindows() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    let recorder = HitRecorder()
    let controller = DemoWindowController(recorder: recorder)

    // Delay setup until the app is up so the run loop / screen are ready.
    DispatchQueue.main.async {
        controller.setUpWindows()
        FileHandle.standardError.write(Data(
            "bench windows: two demo windows are up (space 1 + space 2). Ctrl-C to quit.\n".utf8))
    }
    app.run()
    exit(0)
}

/// Prompt for Accessibility (registers bench in the System Settings list with a
/// toggle) and block until the user grants it, so `run` can be started before
/// the grant exists.
@MainActor
func awaitAccessibility() {
    let opts = ["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary
    if AXIsProcessTrustedWithOptions(opts) { return }
    print("bench: waiting for Accessibility grant — flip the 'bench' toggle in the")
    print("System Settings pane that just opened (up to 3 minutes)…")
    for _ in 0..<180 {
        Thread.sleep(forTimeInterval: 1.0)
        if AXIsProcessTrusted() {
            print("bench: Accessibility granted, starting.")
            return
        }
    }
    FileHandle.standardError.write(Data(
        "bench: no Accessibility grant after 3 minutes; giving up.\n".utf8))
    exit(3)
}

@MainActor
func runMeasurement(_ args: [String]) -> Never {
    guard let modeRaw = parseFlag(args, "--mode"), let mode = BenchMode(rawValue: modeRaw) else {
        FileHandle.standardError.write(Data(
            "usage: bench run --mode native|strafe [--trials N]\n".utf8))
        exit(2)
    }
    let trials = parseFlag(args, "--trials").flatMap { Int($0) } ?? 20

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    awaitAccessibility()

    let machine = MachineInfo.current()
    print(machine.block)

    let recorder = HitRecorder()
    let controller = DemoWindowController(recorder: recorder)

    DispatchQueue.main.async {
        // `run` sets up the windows itself, then runs trials (SPEC).
        controller.setUpWindows()
        let bench = Benchmark(mode: mode, trials: trials, controller: controller, recorder: recorder)
        _ = bench.run(machine: machine)
        controller.teardown()
        exit(0)
    }
    app.run()
    exit(0)
}

/// Characterise gesture shapes (see Sweep.swift). Needs no demo windows — it
/// reads ground truth from CGS — so it is a much lighter run than `bench run`.
@MainActor
func runSweep(_ args: [String]) -> Never {
    let trials = parseFlag(args, "--trials").flatMap { Int($0) } ?? 6
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    awaitAccessibility()
    DispatchQueue.main.async {
        Sweep.run(trials: trials)
        exit(0)
    }
    app.run()
    exit(0)
}

@MainActor
func runSpecs() -> Never {
    print(MachineInfo.current().block)
    exit(0)
}

// When launched via LaunchServices (`open`), stdout/stderr go nowhere — mirror
// them to a log so failures are diagnosable.
if isatty(STDOUT_FILENO) == 0 {
    freopen("/tmp/bench-run.log", "a", stdout)
    freopen("/tmp/bench-run.log", "a", stderr)
    setvbuf(stdout, nil, _IOLBF, 0)
    setvbuf(stderr, nil, _IONBF, 0)
}

let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "windows":
    runWindows()
case "run":
    runMeasurement(Array(args.dropFirst()))
case "sweep":
    runSweep(Array(args.dropFirst()))
case "specs":
    runSpecs()
default:
    FileHandle.standardError.write(Data("""
    bench — time-to-interactivity measurement + demo tooling for strafe

    usage:
      bench windows                                   show demo windows (video takes)
      bench run --mode native|strafe [--trials N]     run the measurement (default N=20)
      bench specs                                      print redacted machine info

    Requires Accessibility. Run the bundled bench.app (bundle-bench.sh) so the
    grant attributes to bench rather than your terminal.

    """.utf8))
    exit(2)
}
