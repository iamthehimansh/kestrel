import XCTest
import SwiftProtobuf
@testable import KestrelStream

@available(macOS 15, *)
final class EmulatorKeyboardTests: XCTestCase {
    func testTextIsBoundedASCIIAndNeverBecomesShellSyntax() throws {
        let text = "Hello %s; $(echo test) ' \""
        let request = try EmulatorKeyboardRequest(text: text)
        XCTAssertEqual(request.message.text, text)
        XCTAssertEqual(request.message.key, "")
        XCTAssertEqual(request.message.eventType, .keypress)
        XCTAssertEqual(request.message.keyCode, 0)
        XCTAssertNoThrow(try EmulatorKeyboardRequest(text: String(repeating: "a", count: 256)))
        for invalid in ["", String(repeating: "a", count: 257), "\n", "\t", "\u{0}", "é", "हिंदी", "🎮"] {
            XCTAssertThrowsError(try EmulatorKeyboardRequest(text: invalid))
        }
    }

    func testBulkASCIIExpandsIntoOrderedSingleCharacterKeypresses() throws {
        let text = "Kestrel keyboard 4"
        let presses = try EmulatorKeyboardRequest(text: text).individualKeypresses
        XCTAssertEqual(presses.count, 18)
        XCTAssertEqual(presses.map { $0.message.text }, text.map(String.init))
        XCTAssertTrue(presses.allSatisfy { $0.message.text.utf8.count == 1 && $0.message.key.isEmpty })
        let ascii = String((32...126).map { Character(UnicodeScalar($0)!) })
        XCTAssertEqual(try EmulatorKeyboardRequest(text: ascii).individualKeypresses.map { $0.message.text }.joined(), ascii)
        XCTAssertEqual(try EmulatorKeyboardRequest(text: String(repeating: "a", count: 256)).individualKeypresses.count, 256)
        let backspace = EmulatorKeyboardRequest(key: .backspace).individualKeypresses
        XCTAssertEqual(backspace.count, 1)
        XCTAssertEqual(backspace[0].message.key, "Backspace")
        XCTAssertEqual(backspace[0].message.text, "")
    }

    func testEditingKeysAreCompletePressesWithNoText() {
        for key in EmulatorKeyboardRequest.EditingKey.allCases {
            let request = EmulatorKeyboardRequest(key: key)
            XCTAssertEqual(request.message.eventType, .keypress)
            XCTAssertEqual(request.message.key, key.rawValue)
            XCTAssertEqual(request.message.text, "")
        }
    }

    func testWireFieldNumbersMatchInstalledProtocol() throws {
        let text = try EmulatorKeyboardRequest(text: "A").message.serializedData()
        XCTAssertEqual(Array(text), [0x10, 2, 0x2a, 1, 65])
        let key = try EmulatorKeyboardRequest(key: .enter).message.serializedData()
        XCTAssertEqual(Array(key), [0x10, 2, 0x22, 5, 69, 110, 116, 101, 114])
    }

    func testInvalidCredentialFailsBeforeConnecting() async throws {
        let client = EmulatorFrameClient(endpoint: try EmulatorFrameEndpoint(host: "127.0.0.1", port: 65530))
        do {
            try await client.sendKey(EmulatorKeyboardRequest(key: .enter), credential: "")
            XCTFail("Empty credential accepted")
        } catch {
            XCTAssertEqual(error as? EmulatorFrameConnectionError, .invalidCredential)
        }
    }
}
