import XCTest
@testable import KestrelKeymap

final class EditingTests: XCTestCase {
    func sample() -> KeymapEditor {
        KeymapEditor(keymap: Keymap(name: "e", controls: [
            .tap(TapControl(key: "F", at: NPoint(0.5, 0.5))),
            .joystick(JoystickControl(up: "W", down: "S", left: "A", right: "D", stick: nil,
                                      center: NPoint(0.15, 0.75), radius: 0.06,
                                      walkKey: nil, walkScale: nil, sprintKey: nil, sprintScale: nil)),
            .swipe(SwipeControl(key: "Space", from: NPoint(0.8, 0.8), to: NPoint(0.8, 0.2), durationMs: 100, mode: nil, label: nil)),
            .macro(MacroControl(key: "M", script: "tap 0.5 0.5", loop: nil, mode: nil, label: nil)),
        ]), aspect: 16.0 / 9.0)
    }

    func testHitTest() {
        let e = sample()
        XCTAssertEqual(e.hitTest(NPoint(0.505, 0.505)), 0)
        XCTAssertEqual(e.hitTest(NPoint(0.18, 0.75)), 1, "anywhere inside the joystick circle")
        XCTAssertEqual(e.hitTest(NPoint(0.8, 0.8)), 2)
        XCTAssertNil(e.hitTest(NPoint(0.3, 0.2)), "empty area")
        XCTAssertNil(e.hitTest(NPoint(0.5, 0.5)).flatMap { $0 == 3 ? $0 : nil }, "macros have no anchor to grab")
    }

    func testMoveTapAndKeepSwipeShape() {
        var e = sample()
        e.move(0, to: NPoint(0.1, 0.2))
        XCTAssertEqual(e.keymap.controls[0].anchor.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(e.keymap.controls[0].anchor.y, 0.2, accuracy: 1e-9)
        e.move(2, to: NPoint(0.5, 0.9))
        guard case .swipe(let s) = e.keymap.controls[2] else { return XCTFail() }
        XCTAssertEqual(s.from.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.from.y, 0.9, accuracy: 1e-9)
        XCTAssertEqual(s.to.y, 0.3, accuracy: 1e-9, "the swipe keeps its length")
    }

    func testMoveClampsWholeControlOnScreen() {
        var e = sample()
        e.move(2, to: NPoint(0.8, 1.0)) // would push `from` to 1.0 and `to` to 0.4: fine
        e.move(2, to: NPoint(0.8, 0.05)) // would push `to` to -0.55: clamped
        guard case .swipe(let s) = e.keymap.controls[2] else { return XCTFail() }
        XCTAssertGreaterThanOrEqual(s.to.y, 0)
        XCTAssertEqual(s.from.y - s.to.y, 0.6, accuracy: 1e-9, "shape preserved while clamped")
    }

    func testResize() {
        var e = sample()
        XCTAssertTrue(e.resize(1, by: 2))
        guard case .joystick(let j) = e.keymap.controls[1] else { return XCTFail() }
        XCTAssertEqual(j.radius, 0.12, accuracy: 1e-9)
        XCTAssertFalse(e.resize(0, by: 2), "a tap has no radius")
        e.resize(1, by: 100)
        guard case .joystick(let j2) = e.keymap.controls[1] else { return XCTFail() }
        XCTAssertEqual(j2.radius, 0.5, "clamped")
    }

    func testAddEveryControlTypeStaysValid() {
        var e = KeymapEditor(keymap: Keymap(name: "blank", controls: []), aspect: 16.0 / 9.0)
        for t in KeymapEditor.addableTypes {
            XCTAssertNotNil(e.addControl(t, at: NPoint(0.4, 0.5)), t)
        }
        XCTAssertEqual(e.keymap.controls.map(\.typeName), KeymapEditor.addableTypes)
        XCTAssertEqual(e.keymap.validate(), [], "every added control gets keys nothing else uses")
        XCTAssertNil(e.addControl("look", at: NPoint(0.5, 0.5)), "only one look control")
        XCTAssertNil(e.addControl("teleport", at: NPoint(0.5, 0.5)))
        // A second joystick and pinch fall back to stick-only and free keys.
        XCTAssertNotNil(e.addControl("joystick", at: NPoint(0.2, 0.7)))
        XCTAssertNotNil(e.addControl("pinch", at: NPoint(0.5, 0.5)))
        XCTAssertNotNil(e.addControl("scroll", at: NPoint(0.5, 0.5)))
        XCTAssertEqual(e.keymap.validate(), [])
    }

    func testFreeKeyRunsOut() {
        var e = KeymapEditor(keymap: Keymap(name: "full", controls: []), aspect: 1)
        var added = 0
        while e.addControl("tap", at: NPoint(0.5, 0.5)) != nil { added += 1 }
        XCTAssertEqual(added, 26 + 10 + 12, "letters, digits and F1-F12")
        XCTAssertNil(e.freeKey())
        XCTAssertEqual(e.keymap.validate(), [])
    }

    func testUpdateAndReplace() {
        var e = sample()
        e.update(0, to: .tap(TapControl(key: "Q", at: NPoint(0.1, 0.1))))
        XCTAssertEqual(e.keymap.controls[0].keys, ["Q"])
        var km = e.keymap
        km.name = "renamed"
        e.replace(with: km)
        XCTAssertEqual(e.keymap.name, "renamed")
    }

    func testRebindAddRemove() {
        var e = sample()
        XCTAssertTrue(e.rebind(0, to: "G"))
        XCTAssertEqual(e.keymap.controls[0].keys, ["G"])
        XCTAssertFalse(e.rebind(1, to: "G"), "joystick keys are edited in JSON")
        XCTAssertFalse(e.rebind(0, to: "NotAKey"))
        let i = e.addTap(at: NPoint(0.3, 0.3), key: "H")
        XCTAssertEqual(i, 4)
        XCTAssertNil(e.addTap(at: NPoint(0.3, 0.3), key: "Nope"))
        e.remove(0)
        XCTAssertEqual(e.keymap.controls.count, 4)
        XCTAssertEqual(e.keymap.validate(), [], "edited keymap stays valid")
    }
}
