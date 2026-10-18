import AppKit
import XCTest
@testable import KestrelStream
@testable import KestrelPlay

final class PlayerKeyboardEventTests: XCTestCase {
    private func event(_ code: UInt16, text: String, flags: NSEvent.ModifierFlags = [],
                       type: NSEvent.EventType = .keyDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }

    func testPrintableCharactersPreserveCaseAndPunctuation() throws {
        for text in ["a", "A", " ", "%", "\""] {
            let request = try XCTUnwrap(PlayerKeyboardEvent.request(for: event(0, text: text, flags: .shift)))
            XCTAssertEqual(request.message.text, text)
            XCTAssertEqual(request.message.key, "")
        }
    }

    func testEditingKeysUseNamedPresses() throws {
        let keys: [(UInt16, String)] = [(0x33, "Backspace"), (0x75, "Delete"), (0x24, "Enter"),
            (0x4C, "Enter"), (0x30, "Tab"), (0x35, "Escape"), (0x7B, "ArrowLeft"),
            (0x7C, "ArrowRight"), (0x7D, "ArrowDown"), (0x7E, "ArrowUp"), (0x73, "Home"), (0x77, "End")]
        for (code, key) in keys {
            let request = try XCTUnwrap(PlayerKeyboardEvent.request(for: event(code, text: "")))
            XCTAssertEqual(request.message.key, key)
            XCTAssertEqual(request.message.text, "")
            XCTAssertEqual(request.message.eventType, .keypress)
        }
    }

    func testHostShortcutsAndUnsupportedModifierCombinationsPassThrough() throws {
        for flags: NSEvent.ModifierFlags in [.command, .control, .option, [.command, .shift]] {
            XCTAssertNil(try PlayerKeyboardEvent.request(for: event(0, text: "a", flags: flags)))
        }
        XCTAssertNil(try PlayerKeyboardEvent.request(for: event(0x30, text: "\t", flags: .shift)))
        XCTAssertNil(try PlayerKeyboardEvent.request(for: event(0x7B, text: "", flags: .shift)))
        XCTAssertNil(try PlayerKeyboardEvent.request(for: event(0, text: "a", type: .keyUp)))
        XCTAssertNil(try PlayerKeyboardEvent.request(for: event(0, text: "")))
    }

    func testUnsupportedTextIsExplicitlyRejectedNotSilentlyDropped() throws {
        for text in ["é", "हिंदी", "🎮", "\u{0}"] {
            XCTAssertThrowsError(try PlayerKeyboardEvent.request(for: event(0, text: text))) {
                XCTAssertEqual($0 as? EmulatorKeyboardRequestError, .unsupportedCharacter)
            }
        }
    }
}
