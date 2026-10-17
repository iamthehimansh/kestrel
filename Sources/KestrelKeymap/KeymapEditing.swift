import Foundation

/// Pure editing operations behind the visual keymap editor, kept free of AppKit so they
/// can be unit-tested.
public struct KeymapEditor: Sendable {
    public private(set) var keymap: Keymap
    /// Screen width / height of the surface being edited (keeps hit circles round).
    public let aspect: Double

    public init(keymap: Keymap, aspect: Double) {
        self.keymap = keymap
        self.aspect = aspect
    }

    /// Hit radius as a fraction of width.
    public static let hitRadius = 0.025

    /// Index of the control whose anchor is nearest to `p` within its hit area, if any.
    /// Joystick and look controls can also be grabbed anywhere inside their circle.
    public func hitTest(_ p: NPoint) -> Int? {
        var best: (Int, Double)?
        for (i, c) in keymap.controls.enumerated() {
            if case .macro = c { continue }
            let a = c.anchor
            let dx = p.x - a.x, dy = (p.y - a.y) / aspect
            let d = (dx * dx + dy * dy).squareRoot()
            var reach = Self.hitRadius
            switch c {
            case .joystick(let j): reach = max(reach, j.radius)
            case .look(let l): reach = max(reach, l.radius * 0.25)
            default: break
            }
            if d <= reach && (best == nil || d < best!.1) { best = (i, d) }
        }
        return best?.0
    }

    /// Moves a control so its anchor lands on `p`. Multi-point controls (swipe, combo)
    /// move as a whole, keeping their shape, and are clamped to stay on screen.
    public mutating func move(_ index: Int, to p: NPoint) {
        guard keymap.controls.indices.contains(index) else { return }
        let c = keymap.controls[index]
        let a = c.anchor
        var dx = p.x - a.x, dy = p.y - a.y
        // Clamp the delta so no point of the control leaves 0...1.
        let pts = points(c)
        if let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
           let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() {
            dx = min(max(dx, -minX), 1 - maxX)
            dy = min(max(dy, -minY), 1 - maxY)
        }
        keymap.controls[index] = c.shifted(dx: dx, dy: dy)
    }

    /// Scales the radius of a joystick, look or skill control. Returns false when the
    /// control has no radius.
    @discardableResult
    public mutating func resize(_ index: Int, by factor: Double) -> Bool {
        guard keymap.controls.indices.contains(index), factor > 0 else { return false }
        let clampR = { (r: Double) in min(max(r, 0.01), 0.5) }
        switch keymap.controls[index] {
        case .joystick(var j): j.radius = clampR(j.radius * factor); keymap.controls[index] = .joystick(j)
        case .look(var l): l.radius = clampR(l.radius * factor); keymap.controls[index] = .look(l)
        case .skill(var s):
            guard s.radius > 0 else { return false }
            s.radius = clampR(s.radius * factor); keymap.controls[index] = .skill(s)
        default: return false
        }
        return true
    }

    /// Rebinds the key of a single-key control. Returns false for multi-key controls
    /// (joystick, pinch, scroll, look), which are edited in the JSON.
    @discardableResult
    public mutating func rebind(_ index: Int, to key: String) -> Bool {
        guard keymap.controls.indices.contains(index), KeyNames.isKnown(key) else { return false }
        switch keymap.controls[index] {
        case .tap(var v): v.key = key; keymap.controls[index] = .tap(v)
        case .turbo(var v): v.key = key; keymap.controls[index] = .turbo(v)
        case .skill(var v): v.key = key; keymap.controls[index] = .skill(v)
        case .swipe(var v): v.key = key; keymap.controls[index] = .swipe(v)
        case .combo(var v): v.key = key; keymap.controls[index] = .combo(v)
        case .macro(var v): v.key = key; keymap.controls[index] = .macro(v)
        default: return false
        }
        return true
    }

    /// Adds a tap control at `p`. Returns its index.
    @discardableResult
    public mutating func addTap(at p: NPoint, key: String) -> Int? {
        guard KeyNames.isKnown(key) else { return nil }
        keymap.controls.append(.tap(TapControl(key: key, at: p.clamped)))
        return keymap.controls.count - 1
    }

    public mutating func remove(_ index: Int) {
        guard keymap.controls.indices.contains(index) else { return }
        keymap.controls.remove(at: index)
    }

    private func points(_ c: Control) -> [NPoint] {
        switch c {
        case .tap(let v): return [v.at]
        case .turbo(let v): return [v.at]
        case .joystick(let v): return [v.center]
        case .look(let v): return [v.center]
        case .skill(let v): return [v.at] + (v.cancelAt.map { [$0] } ?? [])
        case .swipe(let v): return [v.from, v.to]
        case .combo(let v): return v.points
        case .scroll(let v): return [v.at]
        case .pinch(let v): return [v.center]
        case .macro: return []
        }
    }
}

extension Control {
    /// The control moved by (dx, dy) in normalized units; every point moves together.
    /// A skill's cancel area stays where it is (it is a separate screen region).
    public func shifted(dx: Double, dy: Double) -> Control {
        func s(_ p: NPoint) -> NPoint { NPoint(p.x + dx, p.y + dy).clamped }
        switch self {
        case .tap(var v): v.at = s(v.at); return .tap(v)
        case .turbo(var v): v.at = s(v.at); return .turbo(v)
        case .joystick(var v): v.center = s(v.center); return .joystick(v)
        case .look(var v): v.center = s(v.center); return .look(v)
        case .skill(var v): v.at = s(v.at); return .skill(v)
        case .swipe(var v): v.from = s(v.from); v.to = s(v.to); return .swipe(v)
        case .combo(var v): v.points = v.points.map(s); return .combo(v)
        case .scroll(var v): v.at = s(v.at); return .scroll(v)
        case .pinch(var v): v.center = s(v.center); return .pinch(v)
        case .macro: return self
        }
    }
}
