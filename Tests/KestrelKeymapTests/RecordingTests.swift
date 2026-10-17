import XCTest
@testable import KestrelKeymap

final class RecordingTests: XCTestCase {
    func testTokenRoundTrip() {
        let events: [InputEvent] = [
            .keyDown("W"), .keyUp("MouseLeft"), .mouseMove(dx: 12, dy: -3.5), .cursor(NPoint(0.25, 0.75)),
            .wheel(-1), .stick(name: "left", x: 0.5, y: -1), .setLook(true), .setLook(false), .reset,
        ]
        for e in events {
            XCTAssertEqual(InputEvent(token: e.token), e, e.token)
        }
    }

    func testBadTokensRejected() {
        for bad in ["", "keydown", "mouse:1", "mouse:a,b", "stick:left,1", "look:maybe", "fly:1", "wheel:1,2"] {
            XCTAssertNil(InputEvent(token: bad), bad)
        }
    }

    func testSerializeParseRoundTrip() throws {
        let rec = InputRecording(entries: [
            .init(t: 0, event: .keyDown("W")),
            .init(t: 120.5, event: .mouseMove(dx: 4, dy: 0)),
            .init(t: 300, event: .keyUp("W")),
        ])
        XCTAssertEqual(try InputRecording.parse(rec.serialized()), rec)
    }

    func testParseErrors() {
        XCTAssertThrowsError(try InputRecording.parse("10 keydown:W\n5 keyup:W")) { e in
            XCTAssertEqual((e as? MacroScript.ParseError)?.line, 2)
        }
        XCTAssertThrowsError(try InputRecording.parse("abc keydown:W"))
    }

    func testReplayIsDeterministicAndBalanced() throws {
        let km = Keymap(name: "r", controls: [
            .joystick(JoystickControl(up: "W", down: "S", left: "A", right: "D", stick: nil,
                                      center: NPoint(0.15, 0.75), radius: 0.06,
                                      walkKey: nil, walkScale: nil, sprintKey: nil, sprintScale: nil)),
            .turbo(TurboControl(key: "MouseLeft", at: NPoint(0.8, 0.6), intervalMs: 100, mode: nil, label: nil)),
        ])
        let rec = try InputRecording.parse("""
        0 keydown:W
        50 keydown:MouseLeft
        260 keyup:MouseLeft
        400 keyup:W
        """)
        let a = rec.replay(through: KeymapEngine(keymap: km, screenWidth: 1920, screenHeight: 1080))
        let b = rec.replay(through: KeymapEngine(keymap: km, screenWidth: 1920, screenHeight: 1080))
        XCTAssertEqual(a.map(\.op), b.map(\.op))
        let downs = a.filter { if case .down = $0.op { return true }; return false }.count
        let ups = a.filter { if case .up = $0.op { return true }; return false }.count
        XCTAssertEqual(downs, ups, "every finger is lifted by the end")
        XCTAssertEqual(downs, 1 + 3, "joystick + turbo taps at 50, 150, 250 ms")
    }

    func testRecorderTimestampsRelativeToStart() {
        var now: UInt64 = 1_000_000_000
        let r = InputRecorder(clock: { now })
        now += 25_000_000
        r.record(.keyDown("F"), nanos: now)
        now += 10_000_000
        r.record(.keyUp("F"), nanos: now)
        XCTAssertEqual(r.recording.entries.map(\.t), [25, 35])
    }
}
