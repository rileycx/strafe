import AppKit
import ApplicationServices
import CStrafe

/// Dock exposes these notifications through Accessibility. The names are also
/// used by yabai's src/mission_control.c. This tracks Mission Control, App Exposé
/// and Show Desktop independently of Dock's version-sensitive window layers.
/// Start/stop and AX callbacks are main-runloop confined; the engine reads the
/// state from its serial queue under `lock`.
final class MissionControlMonitor: @unchecked Sendable {
    static let shared = MissionControlMonitor()
    private let lock = NSLock()
    private var active = false
    private var observer: AXObserver?
    private var dock: AXUIElement?
    private var launchObserver: (any NSObjectProtocol)?
    private let names = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows",
                         "AXExposeShowDesktop", "AXExposeExit"]

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    private func receive(_ name: String) {
        lock.lock()
        active = name != "AXExposeExit"
        let state = active
        lock.unlock()
        SwitchDiagnostics.log("overlay active=\(state) notification=\(name)")
    }

    func start() {
        precondition(Thread.isMainThread)
        attach()
        if launchObserver == nil {
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == "com.apple.dock" else { return }
                self?.detach()
                self?.attach()
            }
        }
    }

    private func attach() {
        guard observer == nil,
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else { return }
        let application = AXUIElementCreateApplication(pid)
        var created: AXObserver?
        let result = AXObserverCreate(pid, { _, _, notification, refcon in
            guard let refcon else { return }
            Unmanaged<MissionControlMonitor>.fromOpaque(refcon).takeUnretainedValue().receive(notification as String)
        }, &created)
        guard result == .success, let created else {
            SwitchDiagnostics.log("overlay observer unavailable AXError=\(result.rawValue)")
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = 0
        for name in names {
            let status = AXObserverAddNotification(created, application, name as CFString, refcon)
            if status == .success || status == .notificationAlreadyRegistered { registered += 1 }
            else { SwitchDiagnostics.log("overlay notification=\(name) registration AXError=\(status.rawValue)") }
        }
        observer = created
        dock = application
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        // Initial snapshot covers starting while an overlay is already open.
        // Notifications are authoritative after this legacy fallback snapshot.
        lock.lock()
        active = strafe_is_expose_active()
        lock.unlock()
        SwitchDiagnostics.log("overlay observer registered=\(registered)/4 initialActive=\(isActive)")
    }

    private func detach() {
        if let observer {
            if let dock {
                for name in names { AXObserverRemoveNotification(observer, dock, name as CFString) }
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        dock = nil
        lock.lock()
        active = false
        lock.unlock()
    }

    func stop() {
        precondition(Thread.isMainThread)
        detach()
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
    }
}
