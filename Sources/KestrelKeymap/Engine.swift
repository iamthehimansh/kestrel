import Foundation

/// Host-side input fed into the engine.
public enum InputEvent: Equatable, Sendable {
    case keyDown(String)
    case keyUp(String)
    /// Relative mouse motion in host points (only meaningful in look mode).
    case mouseMove(dx: Double, dy: Double)
    /// Absolute cursor position, normalized. Used for skill aiming in cursor mode.
    case cursor(NPoint)
    /// Native player cursor touch, sharing the allocator with mapped game controls.
    case pointerDown(NPoint)
    case pointerMove(NPoint)
    case pointerUp
    /// Wheel notches: positive = up.
    case wheel(Double)
    /// Gamepad stick, values in -1...1 (y down positive). name is "left" / "right".
    case stick(name: String, x: Double, y: Double)
    /// Toggle / set look mode explicitly.
    case setLook(Bool)
    /// Lift every finger and cancel pending timers (focus lost, keymap switch).
    case reset
}

/// Multitouch output in the device's pixel space (MT protocol B slots).
public enum TouchOp: Hashable, Sendable, CustomStringConvertible {
    case down(slot: Int, x: Int, y: Int)
    case move(slot: Int, x: Int, y: Int)
    case up(slot: Int)

    public var description: String {
        switch self {
        case .down(let s, let x, let y): return "down \(s) \(x) \(y)"
        case .move(let s, let x, let y): return "move \(s) \(x) \(y)"
        case .up(let s): return "up \(s)"
        }
    }

    public var slot: Int {
        switch self {
        case .down(let s, _, _), .move(let s, _, _), .up(let s): return s
        }
    }
}

/// Converts host input into touch operations according to a keymap.
///
/// Not thread-safe: drive it from one queue. Time is passed in explicitly (ms) so it can
/// be unit-tested and replayed deterministically.
public final class KeymapEngine {
    public static let maxSlots = 10

    public private(set) var keymap: Keymap
    public let screenWidth: Int
    public let screenHeight: Int
    public private(set) var lookMode: Bool
    public var sensitivity: Double

    private var slotOwner: [Int: String] = [:]
    private var ownerSlot: [String: Int] = [:]
    private var position: [String: NPoint] = [:]
    private var held: Set<String> = []
    private var freeCursorHeld = false
    private var cursor = NPoint(0.5, 0.5)

    // Look state: current finger position offset from center, in normalized x/y.
    private var lookOffset = (x: 0.0, y: 0.0)
    private var rightStick = (x: 0.0, y: 0.0)
    private var leftStick = (x: 0.0, y: 0.0)
    private var lastTick: Double?

    private struct Timer {
        let at: Double
        let seq: Int
        let action: () -> Void
    }
    private var timers: [Timer] = []
    private var seq = 0
    private var now: Double = 0
    private var out: [TouchOp] = []
    /// Generation per owner; timers from a cancelled generation are ignored.
    private var generation: [String: Int] = [:]

    public init(keymap: Keymap, screenWidth: Int, screenHeight: Int, sensitivity: Double = 1.0) {
        self.keymap = keymap
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.sensitivity = sensitivity
        self.lookMode = keymap.startInLook ?? false
    }

    /// Live controls given the current mode.
    private func active(_ c: Control) -> Bool {
        switch c.mode {
        case .always: return true
        case .look: return effectiveLook
        case .cursor: return !effectiveLook
        }
    }

    public var effectiveLook: Bool { lookMode && !freeCursorHeld }

    private var look: LookControl? {
        for c in keymap.controls { if case .look(let l) = c { return l } }
        return nil
    }

    // MARK: - Public API

    /// Feed one event at time `t` (ms). Returns the touch ops to inject now.
    @discardableResult
    public func handle(_ event: InputEvent, at t: Double) -> [TouchOp] {
        out.removeAll()
        runTimers(until: t)
        now = t
        switch event {
        case .keyDown(let k): keyDown(k)
        case .keyUp(let k): keyUp(k)
        case .mouseMove(let dx, let dy): if effectiveLook { lookBy(dx: dx, dy: dy) }
        case .cursor(let p): cursor = p.clamped; updateAimedSkills()
        case .pointerDown(let p):
            if !effectiveLook, p.x.isFinite, p.y.isFinite { fingerDown("native-pointer", p) }
        case .pointerMove(let p):
            if !effectiveLook, p.x.isFinite, p.y.isFinite { fingerMove("native-pointer", p) }
        case .pointerUp: fingerUp("native-pointer")
        case .wheel(let notches): wheel(notches)
        case .stick(let name, let x, let y): stick(name, x, y)
        case .setLook(let on): setLook(on)
        case .reset: resetAll()
        }
        // Gestures the event just scheduled for "now" (macro/combo first step) fire immediately.
        runTimers(until: t)
        now = t
        return out
    }

    /// Advance time with no new input: fires turbo/swipe/macro timers and stick-driven look.
    @discardableResult
    public func tick(at t: Double) -> [TouchOp] {
        out.removeAll()
        let dt = lastTick.map { max(0, min(t - $0, 100)) } ?? 0
        lastTick = t
        runTimers(until: t)
        now = t
        if let l = look, dt > 0, effectiveLook || l.stick != nil, rightStick != (0, 0) {
            let speed = (l.stickSpeed ?? 900) * dt / 1000
            lookBy(dx: rightStick.x * speed, dy: rightStick.y * speed)
        }
        return out
    }

    /// Time of the next pending timer, so a driver can sleep exactly until then.
    public var nextDeadline: Double? { timers.min { $0.at < $1.at }?.at }

    public var hasStickMotion: Bool { rightStick != (0, 0) }

    public var activeTouches: Int { ownerSlot.count }

    public func setKeymap(_ km: Keymap) -> [TouchOp] {
        let ops = handle(.reset, at: now)
        keymap = km
        lookMode = km.startInLook ?? false
        return ops
    }

    // MARK: - Fingers

    private func px(_ p: NPoint) -> (Int, Int) {
        let c = p.clamped
        return (Int((c.x * Double(screenWidth - 1)).rounded()), Int((c.y * Double(screenHeight - 1)).rounded()))
    }

    @discardableResult
    private func fingerDown(_ owner: String, _ p: NPoint) -> Bool {
        if ownerSlot[owner] != nil { fingerUp(owner) }
        guard let slot = (0..<Self.maxSlots).first(where: { slotOwner[$0] == nil }) else { return false }
        slotOwner[slot] = owner
        ownerSlot[owner] = slot
        position[owner] = p
        let (x, y) = px(p)
        out.append(.down(slot: slot, x: x, y: y))
        return true
    }

    private func fingerMove(_ owner: String, _ p: NPoint) {
        guard let slot = ownerSlot[owner] else { return }
        let (ox, oy) = px(position[owner] ?? p)
        position[owner] = p
        let (x, y) = px(p)
        if (x, y) != (ox, oy) { out.append(.move(slot: slot, x: x, y: y)) }
    }

    private func fingerUp(_ owner: String) {
        guard let slot = ownerSlot.removeValue(forKey: owner) else { return }
        slotOwner[slot] = nil
        position[owner] = nil
        out.append(.up(slot: slot))
    }

    private func isDown(_ owner: String) -> Bool { ownerSlot[owner] != nil }

    // MARK: - Timers

    private func schedule(_ delay: Double, owner: String, _ action: @escaping () -> Void) {
        let gen = generation[owner, default: 0]
        seq += 1
        timers.append(Timer(at: now + delay, seq: seq) { [weak self] in
            guard let self, self.generation[owner, default: 0] == gen else { return }
            action()
        })
    }

    private func cancel(_ owner: String) { generation[owner, default: 0] += 1 }

    private func runTimers(until t: Double) {
        while let next = timers.enumerated().min(by: { ($0.element.at, $0.element.seq) < ($1.element.at, $1.element.seq) }),
              next.element.at <= t {
            timers.remove(at: next.offset)
            now = next.element.at
            next.element.action()
        }
    }

    // MARK: - Keys

    private func keyDown(_ key: String) {
        if key == keymap.resolvedLookToggle && look != nil {
            if !held.contains(key) { setLook(!lookMode) }
            held.insert(key)
            return
        }
        if key == keymap.resolvedFreeCursor && lookMode {
            held.insert(key)
            setFreeCursor(true)
            return
        }
        guard !held.contains(key) else { return } // OS key repeat
        held.insert(key)
        for (i, c) in keymap.controls.enumerated() where active(c) && c.keys.contains(key) {
            press(c, index: i, key: key)
        }
    }

    private func keyUp(_ key: String) {
        guard held.remove(key) != nil else { return }
        if key == keymap.resolvedFreeCursor && freeCursorHeld { setFreeCursor(false); return }
        for (i, c) in keymap.controls.enumerated() where c.keys.contains(key) {
            release(c, index: i, key: key)
        }
    }

    private func owner(_ i: Int, _ suffix: String = "") -> String { "c\(i)\(suffix)" }

    private func press(_ c: Control, index i: Int, key: String) {
        switch c {
        case .tap(let v):
            fingerDown(owner(i), v.at)
        case .turbo(let v):
            turboFire(owner(i), v)
        case .joystick(let j):
            updateJoystick(i, j)
        case .look:
            break // scope key only changes sensitivity while held (see lookBy)
        case .skill(let s):
            let o = owner(i)
            fingerDown(o, s.at)
            if s.radius > 0 { aimSkill(i, s) }
            if s.quickCast == true {
                schedule(30, owner: o) { [weak self] in self?.fingerUp(o) }
            }
        case .swipe(let s):
            runSwipe(owner(i), from: s.from, to: s.to, durationMs: s.durationMs)
        case .combo(let cb):
            cancel(owner(i))
            for (k, p) in cb.points.enumerated() {
                let o = owner(i, "#\(k)")
                schedule(Double(k) * cb.intervalMs, owner: owner(i)) { [weak self] in
                    self?.fingerDown(o, p)
                    self?.schedule(MacroScript.tapHoldMs, owner: o) { self?.fingerUp(o) }
                }
            }
        case .scroll(let sc):
            let up = key == (sc.upKey ?? "WheelUp")
            runSwipe(owner(i, up ? "u" : "d"), from: sc.at,
                     to: NPoint(sc.at.x, sc.at.y + (up ? sc.distance : -sc.distance)).clamped,
                     durationMs: sc.durationMs ?? 120)
        case .pinch(let p):
            pinch(i, p, zoomIn: key == p.inKey)
        case .macro(let m):
            runMacro(i, m)
        }
    }

    private func release(_ c: Control, index i: Int, key: String) {
        switch c {
        case .tap:
            fingerUp(owner(i))
        case .turbo:
            cancel(owner(i)); fingerUp(owner(i))
        case .joystick(let j):
            if active(c) { updateJoystick(i, j) } else { fingerUp(owner(i)) }
        case .skill(let s):
            if let ck = s.cancelKey, let cp = s.cancelAt, held.contains(ck) { fingerMove(owner(i), cp) }
            cancel(owner(i))
            fingerUp(owner(i))
        case .macro(let m):
            if m.loop == true { cancel(owner(i)); liftOwned(prefix: owner(i, "#")) }
        case .look, .swipe, .combo, .scroll, .pinch:
            break
        }
    }

    private func liftOwned(prefix: String) {
        for o in ownerSlot.keys.sorted() where o.hasPrefix(prefix) { fingerUp(o) }
    }

    // MARK: - Joystick

    private var aspect: Double { Double(screenWidth) / Double(max(screenHeight, 1)) }

    private func updateJoystick(_ i: Int, _ j: JoystickControl) {
        var dx = 0.0, dy = 0.0
        if let k = j.up, held.contains(k) { dy -= 1 }
        if let k = j.down, held.contains(k) { dy += 1 }
        if let k = j.left, held.contains(k) { dx -= 1 }
        if let k = j.right, held.contains(k) { dx += 1 }
        let fromKeys = dx != 0 || dy != 0
        if !fromKeys, j.stick == "left" { dx = leftStick.x; dy = leftStick.y }
        let mag = (dx * dx + dy * dy).squareRoot()
        let o = owner(i)
        guard mag > 0.15 || (fromKeys && mag > 0) else { fingerUp(o); return }
        // Keys give a unit direction; a stick keeps its analog magnitude.
        var scale = fromKeys ? 1.0 : min(mag, 1.0)
        if let wk = j.walkKey, held.contains(wk) { scale *= j.walkScale ?? 0.5 }
        if let sk = j.sprintKey, held.contains(sk) { scale *= j.sprintScale ?? 1.6 }
        let r = j.radius * scale
        // Radius is a fraction of width; y is scaled by aspect to keep the circle round.
        let target = NPoint(j.center.x + dx / mag * r, j.center.y + dy / mag * r * aspect).clamped
        if !isDown(o) {
            // Touch the stick center first so games register a drag, not a tap at the edge.
            fingerDown(o, j.center)
        }
        fingerMove(o, target)
    }

    private func refreshJoysticks() {
        for (i, c) in keymap.controls.enumerated() {
            if case .joystick(let j) = c { updateJoystick(i, j) }
        }
    }

    // MARK: - Look / aim

    private var lookOwner: String { "look" }

    private func setLook(_ on: Bool) {
        guard on != lookMode else { return }
        lookMode = on
        if !on { fingerUp(lookOwner); lookOffset = (0, 0) }
        modeChanged()
    }

    private func setFreeCursor(_ on: Bool) {
        freeCursorHeld = on
        if on { fingerUp(lookOwner); lookOffset = (0, 0) }
        modeChanged()
    }

    /// Releases controls that just became inactive (e.g. look-only fire button when the
    /// cursor is freed) so no finger is left stuck down.
    private func modeChanged() {
        if effectiveLook { fingerUp("native-pointer") }
        for (i, c) in keymap.controls.enumerated() where !active(c) {
            cancel(owner(i))
            fingerUp(owner(i))
            liftOwned(prefix: owner(i, "#"))
        }
    }

    private func lookBy(dx: Double, dy: Double) {
        guard let l = look else { return }
        var sens = l.sensitivity * sensitivity * (keymap.mouseSensitivity ?? 1)
        if let sk = l.scopeKey, held.contains(sk) { sens *= l.scopeSensitivity ?? 0.5 }
        // 1 host point at sensitivity 1 = 1 device pixel.
        let nx = dx * sens / Double(screenWidth)
        let ny = dy * sens / Double(screenHeight)
        if !isDown(lookOwner) {
            lookOffset = (0, 0)
            guard fingerDown(lookOwner, l.center) else { return }
        }
        var ox = lookOffset.x + nx, oy = lookOffset.y + ny
        // Distance in width-units so the recenter circle is round.
        let dist = (ox * ox + (oy / aspect) * (oy / aspect)).squareRoot()
        if dist > l.radius {
            // Lift and re-press at center, then apply the remaining motion.
            fingerUp(lookOwner)
            guard fingerDown(lookOwner, l.center) else { return }
            ox = nx; oy = ny
        }
        lookOffset = (ox, oy)
        fingerMove(lookOwner, NPoint(l.center.x + ox, l.center.y + oy).clamped)
    }

    // MARK: - Skill aim (MOBA)

    private func aimSkill(_ i: Int, _ s: SkillControl) {
        // Direction from screen center to the cursor, applied around the skill button.
        let dx = cursor.x - 0.5, dy = (cursor.y - 0.5) / aspect
        let mag = (dx * dx + dy * dy).squareRoot()
        guard mag > 0.01 else { return }
        let reach = min(mag / 0.35, 1) * s.radius
        fingerMove(owner(i), NPoint(s.at.x + dx / mag * reach, s.at.y + dy / mag * reach * aspect).clamped)
    }

    private func updateAimedSkills() {
        for (i, c) in keymap.controls.enumerated() {
            if case .skill(let s) = c, s.radius > 0, isDown(owner(i)) { aimSkill(i, s) }
        }
    }

    // MARK: - Timed gestures

    private func turboFire(_ o: String, _ v: TurboControl) {
        fingerDown(o, v.at)
        let hold = min(MacroScript.tapHoldMs, v.intervalMs / 2)
        schedule(hold, owner: o) { [weak self] in self?.fingerUp(o) }
        schedule(v.intervalMs, owner: o) { [weak self] in
            guard let self, self.held.contains(v.key) else { return }
            self.turboFire(o, v)
        }
    }

    private func runSwipe(_ o: String, from a: NPoint, to b: NPoint, durationMs d: Double) {
        cancel(o)
        fingerDown(o, a)
        let n = max(2, Int(d / 16))
        for k in 1...n {
            let u = Double(k) / Double(n)
            schedule(d * u, owner: o) { [weak self] in
                self?.fingerMove(o, NPoint(a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u))
                if k == n { self?.fingerUp(o) }
            }
        }
    }

    private func pinch(_ i: Int, _ p: PinchControl, zoomIn: Bool) {
        let d = p.durationMs ?? 200
        let near = p.spread * 0.15, far = p.spread
        let (s, e) = zoomIn ? (near, far) : (far, near)
        runSwipe(owner(i, "#a"), from: NPoint(p.center.x - s, p.center.y).clamped, to: NPoint(p.center.x - e, p.center.y).clamped, durationMs: d)
        runSwipe(owner(i, "#b"), from: NPoint(p.center.x + s, p.center.y).clamped, to: NPoint(p.center.x + e, p.center.y).clamped, durationMs: d)
    }

    private func wheel(_ notches: Double) {
        guard notches != 0 else { return }
        let key = notches > 0 ? "WheelUp" : "WheelDown"
        for (i, c) in keymap.controls.enumerated() where active(c) && c.keys.contains(key) {
            press(c, index: i, key: key)
        }
    }

    private func runMacro(_ i: Int, _ m: MacroControl) {
        guard let program = try? MacroScript.parse(m.script),
              let (steps, duration) = try? MacroScript.compile(program) else { return }
        let base = owner(i)
        cancel(base)
        liftOwned(prefix: owner(i, "#"))
        for s in steps {
            let o = owner(i, "#" + s.finger)
            schedule(s.t, owner: base) { [weak self] in
                switch s.action {
                case .press(let p): self?.fingerDown(o, p)
                case .move(let p): self?.fingerMove(o, p)
                case .release: self?.fingerUp(o)
                }
            }
        }
        if m.loop == true {
            schedule(max(duration, 16), owner: base) { [weak self] in
                guard let self, self.held.contains(m.key), self.active(.macro(m)) else { return }
                self.runMacro(i, m)
            }
        }
    }

    // MARK: - Gamepad

    private func stick(_ name: String, _ x: Double, _ y: Double) {
        let dead = 0.12
        let v = (abs(x) < dead ? 0 : x, abs(y) < dead ? 0 : y)
        if name == "left" {
            leftStick = v
            refreshJoysticks()
        } else {
            rightStick = v
            if v == (0, 0), !lookMode { fingerUp(lookOwner); lookOffset = (0, 0) }
        }
    }

    private func resetAll() {
        for o in ownerSlot.keys.sorted() { fingerUp(o) }
        for k in generation.keys { generation[k, default: 0] += 1 }
        timers.removeAll()
        held.removeAll()
        freeCursorHeld = false
        lookOffset = (0, 0)
        rightStick = (0, 0)
        leftStick = (0, 0)
    }
}
