import AppKit
import KestrelStream

/// Translation only. The caller must verify host and guest editor focus before sending.
enum PlayerKeyboardEvent {
    static func request(for event: NSEvent) throws -> EmulatorKeyboardRequest? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
        let key: EmulatorKeyboardRequest.EditingKey?
        switch event.keyCode {
        case 0x33: key = .backspace
        case 0x75: key = .delete
        case 0x24, 0x4C: key = .enter
        case 0x30: key = .tab
        case 0x35: key = .escape
        case 0x7B: key = .left
        case 0x7C: key = .right
        case 0x7D: key = .down
        case 0x7E: key = .up
        case 0x73: key = .home
        case 0x77: key = .end
        default: key = nil
        }
        // Shifted navigation/Tab needs modifier semantics; never silently change its meaning.
        if let key {
            guard !event.modifierFlags.contains(.shift) else { return nil }
            return EmulatorKeyboardRequest(key: key)
        }
        guard let text = event.characters, !text.isEmpty else { return nil }
        return try EmulatorKeyboardRequest(text: text)
    }
}
