import XCTest
@testable import KestrelKeymap

final class EngineTests: XCTestCase {
    let W = 1920, H = 1080

    func engine(_ controls: [Control], configure: (inout Keymap) -> Void = { _ in }) -> KeymapEngine {
        var km = Keymap(name: "t", controls: controls)
        configure(&km)
        XCTAssertEqual(km.validate(), [], "keymap under test must be valid")
        return KeymapEngine(keymap: km, screenWidth: W, screenHeight: H)
    }

    func testTapPressAndRelease() {
        let e = engine([.tap(TapControl(key: "F", at: NPoint(0.5, 0.5)))])
        XCTAssertEqual(e.handle(.keyDown("F"), at: 0), [.down(slot: 0, x: 960, y: 540)])
        XCTAssertEqual(e.handle(.keyDown("F"), at: 30), [], "OS key repeat must not re-press")
        XCTAssertEqual(e.handle(.keyUp("F"), at: 60), [.up(slot: 0)])
        XCTAssertEqual(e.activeTouches, 0)
    }

    func testUnmappedKeyDoesNothing() {
        let e = engine([.tap(TapControl(key: "F", at: NPoint(0.5, 0.5)))])
        XCTAssertEqual(e.handle(.keyDown("G"), at: 0), [])
        XCTAssertEqual(e.handle(.keyUp("G"), at: 1), [])
    }

    func testMultitouchUsesSeparateSlots() {
        let e = engine([
            .tap(TapControl(key: "F", at: NPoint(0.1, 0.1))),
            .tap(TapControl(key: "G", at: NPoint(0.9, 0.9))),
        ])
        XCTAssertEqual(e.handle(.keyDown("F"), at: 0).map(\.slot), [0])
        XCTAssertEqual(e.handle(.keyDown("G"), at: 1).map(\.slot), [1])
        XCTAssertEqual(e.handle(.keyUp("F"), at: 2), [.up(slot: 0)])
        // Freed slot is reused.
        XCTAssertEqual(e.handle(.keyDown("F"), at: 3).map(\.slot), [0])
    }

    func joystick() -> Control {
        .joystick(JoystickControl(up: "W", down: "S", left: "A", right: "D", stick: "left",
                                  center: NPoint(0.15, 0.75), radius: 0.06,
                                  walkKey: "Ctrl", walkScale: 0.5, sprintKey: nil, sprintScale: nil))
    }

    func testJoystickWASD() {
        let e = engine([joystick()])
        let cx = Int((0.15 * Double(W - 1)).rounded()), cy = Int((0.75 * Double(H - 1)).rounded())
        let r = 0.06 * Double(W)  // radius in px, kept round on both axes

        let down = e.handle(.keyDown("W"), at: 0)
        XCTAssertEqual(down.first, .down(slot: 0, x: cx, y: cy), "touch starts at stick center")
        guard case .move(0, let x, let y) = down.last else { return XCTFail("expected move, got \(down)") }
        XCTAssertEqual(x, cx)
        XCTAssertEqual(Double(cy - y), r, accuracy: 2, "W pushes straight up by radius")

        // W+D -> diagonal, still on the circle.
        guard case .move(0, let x2, let y2) = e.handle(.keyDown("D"), at: 10).last else { return XCTFail() }
        XCTAssertEqual(Double(x2 - cx), r / 2.squareRoot(), accuracy: 2)
        XCTAssertEqual(Double(cy - y2), r / 2.squareRoot(), accuracy: 2)

        // Walk modifier halves the radius.
        guard case .move(0, _, let y3) = e.handle(.keyDown("Ctrl"), at: 20).last else { return XCTFail() }
        XCTAssertEqual(Double(cy - y3), r / 2 / 2.squareRoot(), accuracy: 2)
        e.handle(.keyUp("Ctrl"), at: 25)

        XCTAssertEqual(e.handle(.keyUp("W"), at: 30).count, 1, "releasing W leaves D held: one move")
        XCTAssertEqual(e.handle(.keyUp("D"), at: 40), [.up(slot: 0)], "all keys up lifts the finger")
    }

    func testJoystickTravelScalesPushWithoutChangingRadius() {
        var j = JoystickControl(up: "W", down: "S", left: "A", right: "D", stick: nil,
                                center: NPoint(0.15, 0.75), radius: 0.06,
                                walkKey: nil, walkScale: nil, sprintKey: nil, sprintScale: nil)
        j.travel = 2
        let e = engine([.joystick(j)])
        let cy = Int((0.75 * Double(H - 1)).rounded())
        guard case .move(0, _, let y) = e.handle(.keyDown("W"), at: 0).last else { return XCTFail() }
        XCTAssertEqual(Double(cy - y), 0.06 * 2 * Double(W), accuracy: 2, "travel 2 doubles the push")

        var editor = KeymapEditor(keymap: Keymap(name: "t", controls: [.joystick(j)]), aspect: 16.0 / 9)
        XCTAssertTrue(editor.adjustTravel(0, by: 10))
        guard case .joystick(let capped) = editor.keymap.controls[0] else { return XCTFail() }
        XCTAssertEqual(capped.travel, 4, "travel is capped at 4")
        XCTAssertEqual(capped.radius, 0.06, "ring size is unchanged")
        XCTAssertTrue(editor.adjustTravel(0, by: 0.25))
        guard case .joystick(let back) = editor.keymap.controls[0] else { return XCTFail() }
        XCTAssertNil(back.travel, "returning to 1x drops the field")
        j.travel = 9
        XCTAssertFalse(Keymap(name: "t", controls: [.joystick(j)]).validate().isEmpty, "out-of-range travel rejected")
    }

    func testJoystickOpposingKeysCancel() {
        let e = engine([joystick()])
        e.handle(.keyDown("A"), at: 0)
        XCTAssertEqual(e.handle(.keyDown("D"), at: 1), [.up(slot: 0)], "A+D cancels out -> finger lifted")
    }

    func testGamepadLeftStickDrivesJoystickWithAnalogMagnitude() {
        let e = engine([joystick()])
        let ops = e.handle(.stick(name: "left", x: 0.5, y: 0), at: 0)
        guard case .move(0, let x, _) = ops.last else { return XCTFail("\(ops)") }
        let cx = Int((0.15 * Double(W - 1)).rounded())
        XCTAssertEqual(Double(x - cx), 0.06 * Double(W) * 0.5, accuracy: 2)
        XCTAssertEqual(e.handle(.stick(name: "left", x: 0.05, y: 0.05), at: 10), [.up(slot: 0)], "deadzone lifts")
    }

    func lookMap() -> [Control] {
        [
            .look(LookControl(center: NPoint(0.65, 0.45), radius: 0.12, sensitivity: 1.0,
                              stick: "right", stickSpeed: 1000, scopeKey: "MouseRight", scopeSensitivity: 0.5)),
            .tap(TapControl(key: "MouseLeft", at: NPoint(0.85, 0.6), mode: .look, label: "Fire")),
            .tap(TapControl(key: "MouseLeft", at: NPoint(0.2, 0.2), mode: .cursor, label: "Click")),
        ]
    }

    func testMouseLookOnlyInLookMode() {
        let e = engine(lookMap())
        XCTAssertEqual(e.handle(.mouseMove(dx: 50, dy: 0), at: 0), [], "cursor mode ignores relative motion")
        XCTAssertEqual(e.handle(.keyDown("Grave"), at: 1), [])
        XCTAssertTrue(e.lookMode)
        let ops = e.handle(.mouseMove(dx: 50, dy: 0), at: 2)
        XCTAssertEqual(ops.count, 2)
        guard case .down(0, let x0, _) = ops[0], case .move(0, let x1, _) = ops[1] else { return XCTFail("\(ops)") }
        XCTAssertEqual(x1 - x0, 50, "sensitivity 1: one host point = one pixel")
    }

    func testMouseLookRecentersPastRadius() {
        let e = engine(lookMap())
        e.handle(.setLook(true), at: 0)
        e.handle(.mouseMove(dx: 10, dy: 0), at: 1)
        // Radius 0.12 * 1920 = 230 px. Another 300 px crosses it.
        let ops = e.handle(.mouseMove(dx: 300, dy: 0), at: 2)
        XCTAssertTrue(ops.contains(.up(slot: 0)), "finger lifts at the edge: \(ops)")
        XCTAssertTrue(ops.contains { if case .down = $0 { return true }; return false }, "and re-presses at center")
    }

    func testScopeKeyLowersSensitivity() {
        let e = engine(lookMap())
        e.handle(.setLook(true), at: 0)
        e.handle(.keyDown("MouseRight"), at: 1)
        let ops = e.handle(.mouseMove(dx: 100, dy: 0), at: 2)
        guard case .down(_, let x0, _) = ops.first, case .move(_, let x1, _) = ops.last else { return XCTFail("\(ops)") }
        XCTAssertEqual(x1 - x0, 50)
    }

    func testFireButtonDependsOnMode() {
        let e = engine(lookMap())
        // Cursor mode: left click hits the "Click" control at (0.2, 0.2).
        XCTAssertEqual(e.handle(.keyDown("MouseLeft"), at: 0), [.down(slot: 0, x: 384, y: 216)])
        e.handle(.keyUp("MouseLeft"), at: 5)
        e.handle(.setLook(true), at: 10)
        guard case .down(_, let x, _) = e.handle(.keyDown("MouseLeft"), at: 20).first else { return XCTFail() }
        XCTAssertEqual(x, Int((0.85 * Double(W - 1)).rounded()), "look mode: left click fires")
    }

    func testLeavingLookModeLiftsLookOnlyFingers() {
        let e = engine(lookMap())
        e.handle(.setLook(true), at: 0)
        e.handle(.mouseMove(dx: 5, dy: 5), at: 1)       // look finger slot 0
        e.handle(.keyDown("MouseLeft"), at: 2)          // fire finger slot 1
        let ops = e.handle(.keyDown("Grave"), at: 3)    // toggle off
        XCTAssertEqual(Set(ops), [.up(slot: 0), .up(slot: 1)])
        XCTAssertEqual(e.activeTouches, 0)
    }

    func testFreeCursorWhileHeld() {
        let e = engine(lookMap())
        e.handle(.setLook(true), at: 0)
        e.handle(.mouseMove(dx: 5, dy: 0), at: 1)
        XCTAssertEqual(e.handle(.keyDown("Alt"), at: 2), [.up(slot: 0)])
        XCTAssertEqual(e.handle(.mouseMove(dx: 5, dy: 0), at: 3), [], "cursor free: no look")
        e.handle(.keyUp("Alt"), at: 4)
        XCTAssertFalse(e.handle(.mouseMove(dx: 5, dy: 0), at: 5).isEmpty, "look resumes")
    }

    func testRightStickLooksOverTime() {
        let e = engine(lookMap())
        e.handle(.stick(name: "right", x: 1, y: 0), at: 0)
        e.tick(at: 0)
        let ops = e.tick(at: 50) // 1000 px/s * 50 ms = 50 px
        guard case .down(_, let x0, _) = ops.first, case .move(_, let x1, _) = ops.last else { return XCTFail("\(ops)") }
        XCTAssertEqual(x1 - x0, 50)
    }

    func testTurboRepeatsWhileHeld() {
        let e = engine([.turbo(TurboControl(key: "MouseLeft", at: NPoint(0.5, 0.5), intervalMs: 100, mode: nil, label: nil))])
        var all = e.handle(.keyDown("MouseLeft"), at: 0)
        for t in stride(from: 10.0, through: 350, by: 10) { all += e.tick(at: t) }
        all += e.handle(.keyUp("MouseLeft"), at: 355)
        for t in stride(from: 360.0, through: 600, by: 10) { all += e.tick(at: t) }
        let downs = all.filter { if case .down = $0 { return true }; return false }.count
        let ups = all.filter { if case .up = $0 { return true }; return false }.count
        XCTAssertEqual(downs, 4, "taps at 0,100,200,300 ms")
        XCTAssertEqual(ups, downs, "every tap is released")
        XCTAssertEqual(e.activeTouches, 0)
    }

    func testSwipeInterpolatesAndReleases() {
        let e = engine([.swipe(SwipeControl(key: "Space", from: NPoint(0.5, 0.8), to: NPoint(0.5, 0.2), durationMs: 160, mode: nil, label: nil))])
        var ops = e.handle(.keyDown("Space"), at: 0)
        XCTAssertEqual(ops.first, .down(slot: 0, x: 960, y: Int((0.8 * Double(H - 1)).rounded())))
        ops += e.tick(at: 200)
        XCTAssertEqual(ops.last, .up(slot: 0))
        XCTAssertEqual(ops.dropLast().last, .move(slot: 0, x: 960, y: Int((0.2 * Double(H - 1)).rounded())))
        XCTAssertGreaterThan(ops.count, 5)
    }

    func testComboTapsInOrder() {
        let pts = [NPoint(0.1, 0.1), NPoint(0.2, 0.2), NPoint(0.3, 0.3)]
        let e = engine([.combo(ComboControl(key: "Q", points: pts, intervalMs: 100, mode: nil, label: nil))])
        var ops = e.handle(.keyDown("Q"), at: 0)
        for t in stride(from: 10.0, through: 400, by: 10) { ops += e.tick(at: t) }
        let downXs = ops.compactMap { op -> Int? in if case .down(_, let x, _) = op { return x }; return nil }
        XCTAssertEqual(downXs, pts.map { Int(($0.x * Double(W - 1)).rounded()) })
        XCTAssertEqual(e.activeTouches, 0)
    }

    func testSkillAimFollowsCursorAndCastsOnRelease() {
        let skill = SkillControl(key: "Q", at: NPoint(0.8, 0.8), radius: 0.08, quickCast: nil,
                                 cancelKey: "Space", cancelAt: NPoint(0.9, 0.2), mode: nil, label: nil)
        let e = engine([.skill(skill)])
        e.handle(.cursor(NPoint(0.9, 0.5)), at: 0) // to the right of center
        let ops = e.handle(.keyDown("Q"), at: 1)
        guard case .down(_, let x0, let y0) = ops.first, case .move(_, let x1, let y1) = ops.last else { return XCTFail("\(ops)") }
        XCTAssertGreaterThan(x1, x0, "dragged toward the cursor")
        XCTAssertEqual(y1, y0)
        XCTAssertEqual(e.handle(.keyUp("Q"), at: 2), [.up(slot: 0)])
    }

    func testSkillCancelMovesToCancelAreaBeforeRelease() {
        let skill = SkillControl(key: "Q", at: NPoint(0.8, 0.8), radius: 0.08, quickCast: nil,
                                 cancelKey: "Space", cancelAt: NPoint(0.9, 0.2), mode: nil, label: nil)
        let e = engine([.skill(skill)])
        e.handle(.keyDown("Q"), at: 0)
        e.handle(.keyDown("Space"), at: 1)
        let ops = e.handle(.keyUp("Q"), at: 2)
        XCTAssertEqual(ops, [.move(slot: 0, x: Int((0.9 * Double(W - 1)).rounded()), y: Int((0.2 * Double(H - 1)).rounded())), .up(slot: 0)])
    }

    func testWheelScroll() {
        let e = engine([.scroll(ScrollControl(at: NPoint(0.5, 0.5), distance: 0.2, durationMs: 100, upKey: nil, downKey: nil, mode: nil))])
        var ops = e.handle(.wheel(1), at: 0)
        ops += e.tick(at: 200)
        guard case .down(_, _, let y0) = ops.first, case .move(_, _, let y1) = ops.dropLast().last else { return XCTFail("\(ops)") }
        XCTAssertGreaterThan(y1, y0, "wheel up drags content down")
        XCTAssertEqual(ops.last, .up(slot: 0))
    }

    func testPinchUsesTwoFingers() {
        let e = engine([.pinch(PinchControl(inKey: "Equal", outKey: "Minus", center: NPoint(0.5, 0.5), spread: 0.2, durationMs: 100, mode: nil))])
        var ops = e.handle(.keyDown("Equal"), at: 0)
        XCTAssertEqual(Set(ops.map(\.slot)), [0, 1])
        ops += e.tick(at: 200)
        XCTAssertEqual(e.activeTouches, 0)
    }

    func testMacroRunsTimedSteps() {
        let script = """
        press A 0.1 0.5
        wait 100
        move A 0.2 0.5
        tap 0.9 0.9
        """
        let e = engine([.macro(MacroControl(key: "E", script: script, loop: nil, mode: nil, label: nil))])
        var ops = e.handle(.keyDown("E"), at: 0)
        XCTAssertEqual(ops.count, 1)
        ops += e.tick(at: 99)
        XCTAssertEqual(ops.count, 1, "nothing before 100 ms")
        ops += e.tick(at: 500)
        XCTAssertEqual(e.activeTouches, 0, "macro lifts all fingers at the end")
        XCTAssertEqual(ops.filter { if case .down = $0 { return true }; return false }.count, 2)
    }

    func testLoopingMacroStopsOnRelease() {
        let e = engine([.macro(MacroControl(key: "E", script: "tap 0.5 0.5\nwait 60", loop: true, mode: nil, label: nil))])
        var ops = e.handle(.keyDown("E"), at: 0)
        for t in stride(from: 10.0, through: 500, by: 10) { ops += e.tick(at: t) }
        ops += e.handle(.keyUp("E"), at: 505)
        for t in stride(from: 510.0, through: 900, by: 10) { ops += e.tick(at: t) }
        let downs = ops.filter { if case .down = $0 { return true }; return false }.count
        XCTAssertEqual(downs, 6, "loops every 100 ms (40 tap + 60 wait): taps at 0,100,…,500, released at 505")
        XCTAssertEqual(e.activeTouches, 0)
    }

    func testResetLiftsEverything() {
        let e = engine([joystick(), .tap(TapControl(key: "F", at: NPoint(0.5, 0.5)))])
        e.handle(.keyDown("W"), at: 0)
        e.handle(.keyDown("F"), at: 1)
        XCTAssertEqual(Set(e.handle(.reset, at: 2)), [.up(slot: 0), .up(slot: 1)])
        XCTAssertEqual(e.handle(.keyUp("W"), at: 3), [], "keys forgotten after reset")
    }

    func testSlotsNeverExceedTen() {
        let controls = (0..<12).map { i in Control.tap(TapControl(key: KeyNames.letters[i], at: NPoint(Double(i) / 12, 0.5))) }
        let e = engine(controls)
        var slots = Set<Int>()
        for i in 0..<12 { for op in e.handle(.keyDown(KeyNames.letters[i]), at: Double(i)) { slots.insert(op.slot) } }
        XCTAssertEqual(slots, Set(0..<10))
        XCTAssertEqual(e.activeTouches, 10)
    }
}
