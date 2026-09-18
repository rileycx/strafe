import AppKit
import Carbon.HIToolbox

/// A physical key plus Carbon modifiers. No keyboard events are persisted.
struct KeyboardShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let allowedModifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.allowedModifiers
    }

    init(event: NSEvent) {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    var validationError: String? {
        guard keyCode < 128, modifiers & ~Self.allowedModifiers == 0,
              ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode) else {
            return "Choose a key together with its modifiers."
        }
        let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 || functionKeys.contains(keyCode) else {
            return "Include Command, Control, or Option, or choose a function key."
        }
        // These chords belong to the system or to editing/closing this window.
        if modifiers == UInt32(cmdKey), [12, 13, 43, 48, 49].contains(keyCode) {
            return "That shortcut is reserved. Add another modifier or choose a different key."
        }
        if modifiers == UInt32(cmdKey | optionKey), keyCode == 53 {
            return "Force Quit is reserved by macOS. Choose a different shortcut."
        }
        return nil
    }

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyName
    }

    private var keyName: String {
        let names: [UInt32: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc",
            65: ".", 67: "*", 69: "+", 71: "Clear", 75: "/", 76: "Enter", 78: "−", 81: "=",
            82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
            114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete", 119: "End", 121: "Page Down",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        if let name = names[keyCode] { return name }
        // Translate against the current keyboard layout, rather than assuming US QWERTY.
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        if let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKey: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKey, characters.count, &length, &characters)
            if status == noErr, length > 0 {
                return String(utf16CodeUnits: characters, count: length).uppercased()
            }
        }
        return "Key \(keyCode)"
    }
}

enum ShortcutAction: String, CaseIterable, Sendable {
    case left, right

    var title: String { self == .left ? "Previous Space" : "Next Space" }
    var storageKey: String { "spaceShortcut.\(rawValue)" }
    var defaultShortcut: KeyboardShortcut {
        KeyboardShortcut(keyCode: UInt32(self == .left ? kVK_LeftArrow : kVK_RightArrow),
                         modifiers: UInt32(controlKey | optionKey))
    }

    var storedShortcut: KeyboardShortcut? {
        guard let data = Preferences.store.data(forKey: storageKey) else { return defaultShortcut }
        // A stored wrapper with no shortcut represents Clear; corrupt data uses the default.
        guard let decoded = try? JSONDecoder().decode(StoredShortcut.self, from: data) else { return defaultShortcut }
        guard let shortcut = decoded.shortcut else { return nil }
        return shortcut.validationError == nil ? shortcut : defaultShortcut
    }

    func persist(_ shortcut: KeyboardShortcut?) {
        if let data = try? JSONEncoder().encode(StoredShortcut(shortcut: shortcut)) {
            Preferences.store.set(data, forKey: storageKey)
        }
    }

    private struct StoredShortcut: Codable { let shortcut: KeyboardShortcut? }
}
