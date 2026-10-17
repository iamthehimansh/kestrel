import Foundation

/// Canonical key names used in keymaps. Keyboard keys use their US-layout label
/// ("W", "1", "Space", "Shift"); mouse buttons and wheel are "MouseLeft", "MouseRight",
/// "MouseMiddle", "Mouse4", "Mouse5", "WheelUp", "WheelDown"; gamepad buttons are
/// "Pad.A" ... "Pad.Menu".
public enum KeyNames {
    public static let letters = (65...90).map { String(UnicodeScalar(UInt8($0))) }
    public static let digits = (0...9).map(String.init)
    public static let named: [String] = [
        "Space", "Enter", "Tab", "Escape", "Backspace", "Delete", "CapsLock",
        "Shift", "RightShift", "Ctrl", "RightCtrl", "Alt", "RightAlt", "Cmd", "RightCmd", "Fn",
        "Up", "Down", "Left", "Right", "Home", "End", "PageUp", "PageDown",
        "Grave", "Minus", "Equal", "LeftBracket", "RightBracket", "Backslash",
        "Semicolon", "Quote", "Comma", "Period", "Slash",
        "Num0", "Num1", "Num2", "Num3", "Num4", "Num5", "Num6", "Num7", "Num8", "Num9",
        "NumPlus", "NumMinus", "NumMultiply", "NumDivide", "NumEnter", "NumDecimal",
    ] + (1...12).map { "F\($0)" }
    public static let mouse = ["MouseLeft", "MouseRight", "MouseMiddle", "Mouse4", "Mouse5", "WheelUp", "WheelDown"]
    public static let pad = ["A", "B", "X", "Y", "L1", "R1", "L2", "R2", "L3", "R3",
                             "Up", "Down", "Left", "Right", "Menu", "Options", "Home"].map { "Pad.\($0)" }

    public static let all: Set<String> = Set(letters + digits + named + mouse + pad)

    public static func isKnown(_ key: String) -> Bool { all.contains(key) }

    /// macOS virtual key code (Carbon kVK_*) -> canonical name.
    public static let macKeyCodes: [UInt16: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H",
        0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P",
        0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7",
        0x1C: "8", 0x19: "9",
        0x31: "Space", 0x24: "Enter", 0x30: "Tab", 0x35: "Escape", 0x33: "Backspace", 0x75: "Delete",
        0x39: "CapsLock", 0x38: "Shift", 0x3C: "RightShift", 0x3B: "Ctrl", 0x3E: "RightCtrl",
        0x3A: "Alt", 0x3D: "RightAlt", 0x37: "Cmd", 0x36: "RightCmd", 0x3F: "Fn",
        0x7E: "Up", 0x7D: "Down", 0x7B: "Left", 0x7C: "Right", 0x73: "Home", 0x77: "End",
        0x74: "PageUp", 0x79: "PageDown",
        0x32: "Grave", 0x1B: "Minus", 0x18: "Equal", 0x21: "LeftBracket", 0x1E: "RightBracket",
        0x2A: "Backslash", 0x29: "Semicolon", 0x27: "Quote", 0x2B: "Comma", 0x2F: "Period", 0x2C: "Slash",
        0x52: "Num0", 0x53: "Num1", 0x54: "Num2", 0x55: "Num3", 0x56: "Num4", 0x57: "Num5",
        0x58: "Num6", 0x59: "Num7", 0x5B: "Num8", 0x5C: "Num9", 0x45: "NumPlus", 0x4E: "NumMinus",
        0x43: "NumMultiply", 0x4B: "NumDivide", 0x4C: "NumEnter", 0x41: "NumDecimal",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6", 0x62: "F7",
        0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]

    /// Short label for overlays ("MouseLeft" -> "LMB").
    public static func shortLabel(_ key: String) -> String {
        switch key {
        case "MouseLeft": return "LMB"
        case "MouseRight": return "RMB"
        case "MouseMiddle": return "MMB"
        case "WheelUp": return "Wh↑"
        case "WheelDown": return "Wh↓"
        case "Space": return "␣"
        case "Shift", "RightShift": return "⇧"
        case "Ctrl", "RightCtrl": return "⌃"
        case "Alt", "RightAlt": return "⌥"
        case "Grave": return "`"
        case "Escape": return "Esc"
        case "CapsLock": return "Caps"
        case "Tab": return "⇥"
        case "Up": return "↑"
        case "Down": return "↓"
        case "Left": return "←"
        case "Right": return "→"
        default:
            return key.hasPrefix("Pad.") ? "🎮" + key.dropFirst(4) : key
        }
    }
}
