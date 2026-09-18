import AppKit
import ApplicationServices
import CStrafe
import Foundation

/// Reads Dock's overlay identifiers off the event-tap thread. macOS 27 can
/// keep a fullscreen layer-20 Dock window even when Mission Control is closed,
/// so window layers alone cannot determine whether a swipe should pass through.
final class DockOverlayMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var generation: UInt64 = 0
    private let queue = DispatchQueue(label: "com.rileycx.strafe.overlay", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private let query: @Sendable () -> Bool

    init(query: @escaping @Sendable () -> Bool = DockOverlayMonitor.readOverlayState) {
        self.query = query
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    /// Called on the main thread with the interceptor lifecycle.
    func start() {
        guard timer == nil else { return }
        lock.lock()
        generation &+= 1
        let token = generation
        // Until the first snapshot arrives, preserve native overlay handling.
        active = true
        lock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let result = self.query()
            self.lock.lock()
            if self.generation == token { self.active = result }
            self.lock.unlock()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        lock.lock()
        generation &+= 1
        active = false
        lock.unlock()
    }

    deinit { timer?.cancel() }

    /// Only root child identifiers are read, never Dock application names or
    /// window contents. The same Accessibility grant used by the tap suffices.
    static func readOverlayState() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return false
        }
        let dock = AXUIElementCreateApplication(process.processIdentifier)
        AXUIElementSetMessagingTimeout(dock, 0.02)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dock, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else {
            // Older systems or an unresponsive Dock retain the existing
            // conservative passthrough heuristic. This runs off the tap thread.
            return strafe_is_expose_active()
        }
        var identifiers: [String] = []
        for child in children.prefix(16) {
            AXUIElementSetMessagingTimeout(child, 0.01)
            var identifier: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &identifier)
            if result == .success, let identifier = identifier as? String {
                identifiers.append(identifier)
            } else if result != .attributeUnsupported && result != .noValue {
                return strafe_is_expose_active()
            }
        }
        return resolveOverlay(identifiers: identifiers)
    }

    /// A successful Accessibility snapshot is authoritative even if Dock still
    /// owns a layer-20 window. Only unavailable snapshots use window metadata.
    static func resolveOverlay(identifiers: [String]?, fallback: () -> Bool = { strafe_is_expose_active() }) -> Bool {
        guard let identifiers else { return fallback() }
        return identifiers.contains("mc") || identifiers.contains("appexpose")
    }
}
