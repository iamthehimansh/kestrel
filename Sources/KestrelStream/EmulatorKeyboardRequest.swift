import Foundation
import GRPCCore

public enum EmulatorKeyboardRequestError: Error, Equatable {
    case emptyText, textTooLarge, unsupportedCharacter
}

/// Keypress-only messages avoid leaving held keys behind after a failed RPC.
public struct EmulatorKeyboardRequest: Sendable {
    public enum EditingKey: String, CaseIterable, Sendable {
        case backspace = "Backspace", delete = "Delete", enter = "Enter", tab = "Tab"
        case left = "ArrowLeft", right = "ArrowRight", up = "ArrowUp", down = "ArrowDown"
        case home = "Home", end = "End", escape = "Escape"
    }
    private let text: String?
    private let key: EditingKey?

    public init(text: String) throws {
        guard !text.isEmpty else { throw EmulatorKeyboardRequestError.emptyText }
        guard text.utf8.count <= 256 else { throw EmulatorKeyboardRequestError.textTooLarge }
        guard text.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) else {
            throw EmulatorKeyboardRequestError.unsupportedCharacter
        }
        self.text = text
        key = nil
    }

    public init(key: EditingKey) { self.key = key; text = nil }

    /// The emulator can acknowledge bulk text without inserting it. Always send
    /// printable ASCII as individual keypresses, in order, never as shell input.
    public var individualKeypresses: [EmulatorKeyboardRequest] {
        guard let text else { return [self] }
        return text.map { EmulatorKeyboardRequest(asciiCharacter: $0) }
    }

    private init(asciiCharacter: Character) {
        text = String(asciiCharacter)
        key = nil
    }

    var message: Android_Emulation_Control_KeyboardEvent {
        var value = Android_Emulation_Control_KeyboardEvent()
        value.eventType = .keypress
        if let text { value.text = text }
        if let key { value.key = key.rawValue }
        return value
    }

    @available(macOS 15, *)
    var options: CallOptions {
        var options = CallOptions.defaults
        options.timeout = .seconds(2)
        options.waitForReady = false
        options.maxRequestMessageBytes = 4096
        options.maxResponseMessageBytes = 4096
        return options
    }
}
