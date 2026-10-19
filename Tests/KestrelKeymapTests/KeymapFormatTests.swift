import XCTest
@testable import KestrelKeymap

final class KeymapFormatTests: XCTestCase {
    func testDecodeAllControlTypes() throws {
        let json = """
        {
          "name": "demo", "package": "com.example.game",
          "controls": [
            {"type": "tap", "key": "F", "at": [0.5, 0.5]},
            {"type": "fire", "key": "MouseLeft", "at": {"x": 0.8, "y": 0.6}, "mode": "look"},
            {"type": "turbo", "key": "R", "at": [0.7, 0.7], "intervalMs": 80},
            {"type": "joystick", "up": "W", "down": "S", "left": "A", "right": "D", "center": [0.15, 0.75], "radius": 0.06},
            {"type": "aim", "center": [0.6, 0.4], "radius": 0.1, "sensitivity": 1.2},
            {"type": "skill", "key": "Q", "at": [0.8, 0.85], "radius": 0.07},
            {"type": "swipe", "key": "Space", "from": [0.5, 0.8], "to": [0.5, 0.3], "durationMs": 120},
            {"type": "combo", "key": "C", "points": [[0.1, 0.1], [0.2, 0.2]], "intervalMs": 60},
            {"type": "scroll", "at": [0.5, 0.5], "distance": 0.15},
            {"type": "pinch", "inKey": "Equal", "outKey": "Minus", "center": [0.5, 0.5], "spread": 0.2},
            {"type": "macro", "key": "E", "script": "tap 0.5 0.5\\nwait 50"}
          ]
        }
        """
        let km = try Keymap.decode(Data(json.utf8))
        XCTAssertEqual(km.controls.map(\.typeName),
                       ["tap", "tap", "turbo", "joystick", "look", "skill", "swipe", "combo", "scroll", "pinch", "macro"])
        XCTAssertEqual(km.validate(), [])
        // Round trip.
        XCTAssertEqual(try Keymap.decode(km.encoded()), km)
    }

    func testUnknownTypeFails() {
        let json = #"{"name":"x","controls":[{"type":"teleport","key":"F"}]}"#
        XCTAssertThrowsError(try Keymap.decode(Data(json.utf8)))
    }

    func testValidationCatchesProblems() {
        let km = Keymap(name: "bad", controls: [
            .tap(TapControl(key: "F", at: NPoint(1.5, 0.5))),
            .tap(TapControl(key: "F", at: NPoint(0.5, 0.5))),
            .tap(TapControl(key: "Banana", at: NPoint(0.5, 0.5))),
            .macro(MacroControl(key: "M", script: "fly 1 2", loop: nil, mode: nil, label: nil)),
        ])
        let p = km.validate()
        XCTAssertTrue(p.contains { $0.contains("outside 0...1") }, "\(p)")
        XCTAssertFalse(p.contains { $0.contains("already used") }, "\(p)")
        XCTAssertTrue(p.contains { $0.contains("unknown key 'Banana'") }, "\(p)")
        XCTAssertTrue(p.contains { $0.contains("unknown command 'fly'") }, "\(p)")
    }

    func testOneKeyPressesSeveralPlaces() {
        let km = Keymap(name: "multi", controls: [
            .tap(TapControl(key: "F", at: NPoint(0.2, 0.5))),
            .tap(TapControl(key: "F", at: NPoint(0.5, 0.5))),
            .tap(TapControl(key: "F", at: NPoint(0.8, 0.5))),
        ])
        XCTAssertEqual(km.validate(), [])
        let e = KeymapEngine(keymap: km, screenWidth: 1000, screenHeight: 500)
        let downs = e.handle(.keyDown("F"), at: 0).filter { if case .down = $0 { return true }; return false }
        XCTAssertEqual(downs.count, 3, "one key press touches all three places")
    }

    func testSameKeyAllowedInDifferentModes() {
        let km = Keymap(name: "ok", controls: [
            .tap(TapControl(key: "MouseLeft", at: NPoint(0.5, 0.5), mode: .look)),
            .tap(TapControl(key: "MouseLeft", at: NPoint(0.2, 0.2), mode: .cursor)),
        ])
        XCTAssertEqual(km.validate(), [])
    }

    func testMacroParseErrorsHaveLineNumbers() {
        XCTAssertThrowsError(try MacroScript.parse("tap 0.5 0.5\nrepeat 2\ntap 0.1 0.1")) { e in
            XCTAssertEqual((e as? MacroScript.ParseError)?.message, "'repeat' without 'end'")
        }
        XCTAssertThrowsError(try MacroScript.parse("tap 0.5\n")) { e in
            XCTAssertEqual((e as? MacroScript.ParseError)?.line, 1)
        }
        XCTAssertThrowsError(try MacroScript.parse("end"))
        XCTAssertThrowsError(try MacroScript.parse("press 0.1 0.2 0.3"), "finger name is required")
    }

    func testMacroCompileTiming() throws {
        let (steps, duration) = try MacroScript.compile(MacroScript.parse("""
        repeat 2
          tap 0.5 0.5
          wait 10
        end
        press F 0.1 0.1
        """))
        XCTAssertEqual(duration, 2 * (MacroScript.tapHoldMs + 10))
        XCTAssertEqual(steps.count, 2 * 2 + 2, "two taps (down+up each) + press + auto-release")
        XCTAssertEqual(steps.last?.action, .release)
    }

    func testMacroExpansionLimit() {
        XCTAssertThrowsError(try MacroScript.compile(MacroScript.parse("repeat 1000\nrepeat 1000\ntap 0.5 0.5\nend\nend")))
    }

    func testBundledPresetsAreValid() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("keymaps")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertGreaterThanOrEqual(files.count, 6, "expected the bundled game presets")
        for f in files {
            let km = try Keymap.load(f)
            XCTAssertEqual(km.validate(), [], f.lastPathComponent)
            XCTAssertNotNil(km.package, "\(f.lastPathComponent) should name its Android package")
        }
    }
}
