import AppKit

/// Captures keys only as the first responder of strafe's visible settings window.
/// No global monitor (or keyboard event tap) is installed.
@MainActor
private final class ShortcutRecorder: NSButton {
    var recording = false
    var onRecord: ((NSEvent) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onCancel?()
        } else if !event.isARepeat {
            onRecord?(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let hotkeys: HotkeyManager
    private let engine: GestureSwitchEngine?
    private let interceptor: SwipeInterceptor
    private var recorders: [ShortcutAction: ShortcutRecorder] = [:]
    private var recordingAction: ShortcutAction?
    private let enableShortcuts = NSButton(checkboxWithTitle: "Enable keyboard shortcuts", target: nil, action: nil)
    private static let speedPresets = TransitionSpeed.allCases
    private let speed = NSSlider()
    private let speedValue = NSTextField(labelWithString: "")
    private let dragToSwitch = NSButton(checkboxWithTitle: "Drag to switch Spaces", target: nil, action: nil)
    private let flickSensitivity = NSSlider(
        value: Double(SwipeInterceptor.defaultFlickSensitivity),
        minValue: Double(SwipeInterceptor.flickSensitivityRange.lowerBound),
        maxValue: Double(SwipeInterceptor.flickSensitivityRange.upperBound),
        target: nil, action: nil)
    private let flickSensitivityValue = NSTextField(labelWithString: "")
    private let message = NSTextField(wrappingLabelWithString: "")
    private let swipeStatus = NSTextField(wrappingLabelWithString: "")
    private var statusTimer: Timer?

    init(hotkeys: HotkeyManager, engine: GestureSwitchEngine?, interceptor: SwipeInterceptor) {
        self.hotkeys = hotkeys
        self.engine = engine
        self.interceptor = interceptor
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "strafe Settings"
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("strafe.settings")
        super.init(window: window)
        window.delegate = self
        window.center()
        buildContent()
        hotkeys.onStateChanged = { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func showSettings() {
        refresh()
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSwipeStatus() }
        }
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)
        ])

        let heading = NSTextField(labelWithString: "Keyboard shortcuts")
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        stack.addArrangedSubview(heading)
        enableShortcuts.target = self
        enableShortcuts.action = #selector(toggleShortcuts)
        stack.addArrangedSubview(enableShortcuts)

        for action in ShortcutAction.allCases {
            let label = NSTextField(labelWithString: action.title)
            label.widthAnchor.constraint(equalToConstant: 135).isActive = true
            let recorder = ShortcutRecorder(title: "", target: self, action: #selector(beginRecording(_:)))
            recorder.bezelStyle = .rounded
            recorder.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            recorder.widthAnchor.constraint(equalToConstant: 210).isActive = true
            recorder.setAccessibilityLabel("\(action.title) shortcut")
            recorder.onRecord = { [weak self] event in self?.record(event, for: action) }
            recorder.onCancel = { [weak self] in self?.cancelRecording() }
            recorders[action] = recorder
            let clear = NSButton(title: "Clear", target: self, action: #selector(clearShortcut(_:)))
            clear.bezelStyle = .rounded
            clear.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
            let row = NSStackView(views: [label, recorder, clear])
            row.spacing = 10
            stack.addArrangedSubview(row)
        }
        let help = NSTextField(wrappingLabelWithString: "Click a shortcut, then press a key with ⌘, ⌃, or ⌥ (or a function key). Press Esc to cancel. Changes apply immediately.")
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(help)
        help.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let reset = NSButton(title: "Restore Default Shortcuts", target: self, action: #selector(restoreDefaults))
        reset.bezelStyle = .rounded
        stack.addArrangedSubview(reset)

        message.font = .systemFont(ofSize: 12)
        message.textColor = .systemRed
        stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        message.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true

        let divider = NSBox()
        divider.boxType = .separator
        stack.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let transitions = NSTextField(labelWithString: "Space transitions")
        transitions.font = .systemFont(ofSize: 16, weight: .semibold)
        stack.addArrangedSubview(transitions)
        speed.target = self
        speed.action = #selector(changeSpeed)
        speed.isEnabled = engine != nil
        speed.setAccessibilityLabel("Transition speed for swipes and keyboard shortcuts")
        speed.minValue = 0
        speed.maxValue = Double(Self.speedPresets.count - 1)
        speed.numberOfTickMarks = Self.speedPresets.count
        speed.allowsTickMarkValuesOnly = true
        speedValue.alignment = .right
        speedValue.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let speedRow = NSStackView(views: [NSTextField(labelWithString: "Transition speed"), speed, speedValue])
        speedRow.spacing = 8
        stack.addArrangedSubview(speedRow)
        speedRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let speedHelp = NSTextField(wrappingLabelWithString: "Applies to shortcuts, swipes, and the end of a drag.")
        speedHelp.font = .systemFont(ofSize: 12)
        speedHelp.textColor = .secondaryLabelColor
        stack.addArrangedSubview(speedHelp)
        speedHelp.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let gestureDivider = NSBox()
        gestureDivider.boxType = .separator
        stack.addArrangedSubview(gestureDivider)
        gestureDivider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let gestures = NSTextField(labelWithString: "Trackpad gestures")
        gestures.font = .systemFont(ofSize: 16, weight: .semibold)
        stack.addArrangedSubview(gestures)
        dragToSwitch.target = self
        dragToSwitch.action = #selector(toggleDragToSwitch)
        stack.addArrangedSubview(dragToSwitch)
        let dragHelp = NSTextField(wrappingLabelWithString: "Hold to preview. Release at or past halfway, or flick to switch.")
        dragHelp.font = .systemFont(ofSize: 12)
        dragHelp.textColor = .secondaryLabelColor
        stack.addArrangedSubview(dragHelp)
        dragHelp.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let flickLabel = NSTextField(labelWithString: "Flick sensitivity")
        flickSensitivity.target = self
        flickSensitivity.action = #selector(changeFlickSensitivity)
        flickSensitivity.setAccessibilityLabel(flickLabel.stringValue)
        flickSensitivity.toolTip = "Higher values make lighter flicks switch Spaces."
        flickSensitivityValue.alignment = .right
        flickSensitivityValue.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let flickRow = NSStackView(views: [flickLabel, flickSensitivity, flickSensitivityValue])
        flickRow.spacing = 8
        stack.addArrangedSubview(flickRow)
        flickRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        swipeStatus.font = .systemFont(ofSize: 12)
        swipeStatus.textColor = .secondaryLabelColor
        stack.addArrangedSubview(swipeStatus)
        swipeStatus.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24).isActive = true
        window?.setContentSize(NSSize(width: 550, height: 600))
    }

    private func refresh() {
        enableShortcuts.state = HotkeyManager.enabled ? .on : .off
        dragToSwitch.state = interceptor.dragToSwitch ? .on : .off
        refreshFlickSensitivity()
        for action in ShortcutAction.allCases {
            let recorder = recorders[action]!
            recorder.recording = recordingAction == action
            recorder.title = recorder.recording ? "Type shortcut… (Esc cancels)" : (action.storedShortcut?.displayName ?? "Record Shortcut…")
        }
        if let error = hotkeys.registrationError { message.stringValue = error }
        let selected = engine?.transitionSpeed ?? TransitionSpeed.stored
        speed.integerValue = Self.speedPresets.firstIndex(of: selected) ?? 0
        speedValue.stringValue = selected.title
        refreshSwipeStatus()
    }

    private func refreshFlickSensitivity() {
        flickSensitivity.isEnabled = interceptor.dragToSwitch
        flickSensitivity.integerValue = interceptor.flickSensitivity
        flickSensitivityValue.stringValue = "\(interceptor.flickSensitivity)%"
    }

    private func refreshSwipeStatus() {
        swipeStatus.stringValue = interceptor.statusDescription
    }

    @objc private func beginRecording(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let action = ShortcutAction(rawValue: value) else { return }
        recordingAction = action
        message.stringValue = ""
        hotkeys.setRecording(true)
        refresh()
        window?.makeFirstResponder(sender)
    }

    private func record(_ event: NSEvent, for action: ShortcutAction) {
        let shortcut = KeyboardShortcut(event: event)
        if let error = shortcut.validationError {
            message.stringValue = error
            return
        }
        recordingAction = nil
        let error = hotkeys.updateShortcut(shortcut, for: action)
        // Duplicate validation happens before updateShortcut resumes registration.
        hotkeys.setRecording(false)
        refresh()
        message.stringValue = error ?? ""
    }

    private func cancelRecording() {
        recordingAction = nil
        hotkeys.setRecording(false)
        refresh()
    }

    @objc private func clearShortcut(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let action = ShortcutAction(rawValue: value) else { return }
        cancelRecording()
        let error = hotkeys.updateShortcut(nil, for: action)
        refresh()
        message.stringValue = error ?? ""
    }

    @objc private func restoreDefaults() {
        cancelRecording()
        let error = hotkeys.restoreDefaultShortcuts()
        refresh()
        message.stringValue = error ?? ""
    }

    @objc private func toggleShortcuts() {
        let enabled = enableShortcuts.state == .on
        cancelRecording()
        HotkeyManager.persist(enabled: enabled)
        hotkeys.applyStoredState()
        message.stringValue = hotkeys.registrationError ?? ""
        refresh()
    }

    @objc private func toggleDragToSwitch() {
        interceptor.setDragToSwitch(dragToSwitch.state == .on)
        refreshFlickSensitivity()
    }

    @objc private func changeFlickSensitivity() {
        interceptor.setFlickSensitivity(flickSensitivity.integerValue)
        refreshFlickSensitivity()
    }

    @objc private func changeSpeed() {
        let selected = Self.speedPresets[speed.integerValue]
        speedValue.stringValue = selected.title
        guard let engine, engine.transitionSpeed != selected else { return }
        selected.persist()
        engine.setTransitionSpeed(selected)
    }

    func windowDidResignKey(_ notification: Notification) { cancelRecording() }
    func windowWillClose(_ notification: Notification) {
        cancelRecording()
        statusTimer?.invalidate()
        statusTimer = nil
    }
}
