import Foundation

/// A point in normalized screen space: (0,0) top-left, (1,1) bottom-right of the
/// instance's display, so one keymap works at any resolution.
/// JSON form: [x, y] (an {"x":..,"y":..} object is also accepted).
public struct NPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    enum CodingKeys: String, CodingKey { case x, y }

    public init(from decoder: Decoder) throws {
        if var arr = try? decoder.unkeyedContainer() {
            x = try arr.decode(Double.self)
            y = try arr.decode(Double.self)
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            x = try c.decode(Double.self, forKey: .x)
            y = try c.decode(Double.self, forKey: .y)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var arr = encoder.unkeyedContainer()
        try arr.encode((x * 10000).rounded() / 10000)
        try arr.encode((y * 10000).rounded() / 10000)
    }

    public var clamped: NPoint { NPoint(min(max(x, 0), 1), min(max(y, 0), 1)) }
    public var isNormalized: Bool { (0...1).contains(x) && (0...1).contains(y) }
}

/// When a control is live.
/// - always: in both modes.
/// - look:   only while mouse-look (cursor locked, "aim mode") is on. Used for fire buttons
///           so the left mouse button still clicks normally when the cursor is free.
/// - cursor: only while the cursor is free.
public enum ControlMode: String, Codable, Sendable {
    case always, look, cursor
}

public struct TapControl: Codable, Equatable, Sendable {
    public var key: String
    public var at: NPoint
    public var mode: ControlMode?
    public var label: String?
    public init(key: String, at: NPoint, mode: ControlMode? = nil, label: String? = nil) {
        self.key = key; self.at = at; self.mode = mode; self.label = label
    }
}

/// Auto-fire: taps repeatedly while the key is held.
public struct TurboControl: Codable, Equatable, Sendable {
    public var key: String
    public var at: NPoint
    public var intervalMs: Double
    public var mode: ControlMode?
    public var label: String?
}

/// Virtual joystick from four keys (WASD) and/or a gamepad stick.
public struct JoystickControl: Codable, Equatable, Sendable {
    public var up: String?
    public var down: String?
    public var left: String?
    public var right: String?
    /// "left" or "right" gamepad stick.
    public var stick: String?
    public var center: NPoint
    /// Radius as a fraction of screen width.
    public var radius: Double
    /// Hold to move at reduced radius (walk instead of run).
    public var walkKey: String?
    public var walkScale: Double?
    /// Hold to push past the joystick edge (sprint/auto-run lock in many shooters).
    public var sprintKey: String?
    public var sprintScale: Double?
}

/// Mouse-look / aim: relative mouse motion drags a finger from `center`; when the finger
/// drifts past `radius` it lifts and re-presses at center, giving unlimited turning.
public struct LookControl: Codable, Equatable, Sendable {
    public var center: NPoint
    public var radius: Double
    public var sensitivity: Double
    /// Gamepad stick that also drives look ("right").
    public var stick: String?
    /// Stick speed in mouse-pixels per second at full deflection.
    public var stickSpeed: Double?
    /// Hold for a lower sensitivity (scoped aim).
    public var scopeKey: String?
    public var scopeSensitivity: Double?
}

/// Skill button with optional aiming (MOBA style): press holds the button and drags it
/// towards the cursor's direction from screen center, release casts.
public struct SkillControl: Codable, Equatable, Sendable {
    public var key: String
    public var at: NPoint
    /// Drag radius (fraction of screen width). 0 = plain tap-and-hold.
    public var radius: Double
    /// Cast immediately on press instead of on release.
    public var quickCast: Bool?
    /// Cancel area: if the key is released while `cancelKey` is held, drag here first.
    public var cancelKey: String?
    public var cancelAt: NPoint?
    public var mode: ControlMode?
    public var label: String?
}

public struct SwipeControl: Codable, Equatable, Sendable {
    public var key: String
    public var from: NPoint
    public var to: NPoint
    public var durationMs: Double
    public var mode: ControlMode?
    public var label: String?
}

/// Several taps in sequence from one key press.
public struct ComboControl: Codable, Equatable, Sendable {
    public var key: String
    public var points: [NPoint]
    public var intervalMs: Double
    public var mode: ControlMode?
    public var label: String?
}

/// Mouse wheel turned into a vertical (or zoom) swipe.
public struct ScrollControl: Codable, Equatable, Sendable {
    public var at: NPoint
    public var distance: Double
    public var durationMs: Double?
    public var upKey: String?
    public var downKey: String?
    public var mode: ControlMode?
}

/// Two-finger pinch on keys (zoom in/out maps, scopes).
public struct PinchControl: Codable, Equatable, Sendable {
    public var inKey: String
    public var outKey: String
    public var center: NPoint
    public var spread: Double
    public var durationMs: Double?
    public var mode: ControlMode?
}

/// Script-driven control, see MacroScript for the language.
public struct MacroControl: Codable, Equatable, Sendable {
    public var key: String
    public var script: String
    /// Re-run the macro for as long as the key stays held.
    public var loop: Bool?
    public var mode: ControlMode?
    public var label: String?
}

public enum Control: Codable, Equatable, Sendable {
    case tap(TapControl)
    case turbo(TurboControl)
    case joystick(JoystickControl)
    case look(LookControl)
    case skill(SkillControl)
    case swipe(SwipeControl)
    case combo(ComboControl)
    case scroll(ScrollControl)
    case pinch(PinchControl)
    case macro(MacroControl)

    enum TypeKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "tap", "fire": self = .tap(try TapControl(from: decoder))
        case "turbo": self = .turbo(try TurboControl(from: decoder))
        case "joystick": self = .joystick(try JoystickControl(from: decoder))
        case "look", "aim": self = .look(try LookControl(from: decoder))
        case "skill": self = .skill(try SkillControl(from: decoder))
        case "swipe": self = .swipe(try SwipeControl(from: decoder))
        case "combo": self = .combo(try ComboControl(from: decoder))
        case "scroll": self = .scroll(try ScrollControl(from: decoder))
        case "pinch": self = .pinch(try PinchControl(from: decoder))
        case "macro": self = .macro(try MacroControl(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: try decoder.container(keyedBy: TypeKey.self),
                                                   debugDescription: "unknown control type '\(type)'")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TypeKey.self)
        try c.encode(typeName, forKey: .type)
        switch self {
        case .tap(let v): try v.encode(to: encoder)
        case .turbo(let v): try v.encode(to: encoder)
        case .joystick(let v): try v.encode(to: encoder)
        case .look(let v): try v.encode(to: encoder)
        case .skill(let v): try v.encode(to: encoder)
        case .swipe(let v): try v.encode(to: encoder)
        case .combo(let v): try v.encode(to: encoder)
        case .scroll(let v): try v.encode(to: encoder)
        case .pinch(let v): try v.encode(to: encoder)
        case .macro(let v): try v.encode(to: encoder)
        }
    }

    public var typeName: String {
        switch self {
        case .tap: return "tap"
        case .turbo: return "turbo"
        case .joystick: return "joystick"
        case .look: return "look"
        case .skill: return "skill"
        case .swipe: return "swipe"
        case .combo: return "combo"
        case .scroll: return "scroll"
        case .pinch: return "pinch"
        case .macro: return "macro"
        }
    }

    public var mode: ControlMode {
        switch self {
        case .tap(let v): return v.mode ?? .always
        case .turbo(let v): return v.mode ?? .always
        case .skill(let v): return v.mode ?? .always
        case .swipe(let v): return v.mode ?? .always
        case .combo(let v): return v.mode ?? .always
        case .scroll(let v): return v.mode ?? .always
        case .pinch(let v): return v.mode ?? .always
        case .macro(let v): return v.mode ?? .always
        case .joystick, .look: return .always
        }
    }

    /// Keys this control reacts to.
    public var keys: [String] {
        switch self {
        case .tap(let v): return [v.key]
        case .turbo(let v): return [v.key]
        case .joystick(let v): return [v.up, v.down, v.left, v.right, v.walkKey, v.sprintKey].compactMap { $0 }
        case .look(let v): return [v.scopeKey].compactMap { $0 }
        case .skill(let v): return [v.key]
        case .swipe(let v): return [v.key]
        case .combo(let v): return [v.key]
        case .scroll(let v): return [v.upKey ?? "WheelUp", v.downKey ?? "WheelDown"]
        case .pinch(let v): return [v.inKey, v.outKey]
        case .macro(let v): return [v.key]
        }
    }

    /// Where the on-screen hint is drawn.
    public var anchor: NPoint {
        switch self {
        case .tap(let v): return v.at
        case .turbo(let v): return v.at
        case .joystick(let v): return v.center
        case .look(let v): return v.center
        case .skill(let v): return v.at
        case .swipe(let v): return v.from
        case .combo(let v): return v.points.first ?? NPoint(0.5, 0.5)
        case .scroll(let v): return v.at
        case .pinch(let v): return v.center
        case .macro: return NPoint(0.5, 0.5)
        }
    }
}

public struct Keymap: Codable, Equatable, Sendable {
    public var name: String
    /// Android package this keymap belongs to; play mode auto-loads it for that app.
    public var package: String?
    public var description: String?
    /// Screen width / height the keymap was designed for (used to keep joystick and look
    /// circles round). Defaults to 16:9.
    public var aspect: Double?
    /// Toggles mouse-look (cursor lock). Default "Grave" (the ` key).
    public var lookToggleKey: String?
    /// Hold to temporarily free the cursor while in look mode. Default "Alt".
    public var freeCursorKey: String?
    /// Start in look mode.
    public var startInLook: Bool?
    /// Global multiplier on look sensitivity.
    public var mouseSensitivity: Double?
    public var controls: [Control]

    public init(name: String, package: String? = nil, controls: [Control]) {
        self.name = name
        self.package = package
        self.controls = controls
    }

    public var resolvedAspect: Double { aspect ?? 16.0 / 9.0 }
    public var resolvedLookToggle: String { lookToggleKey ?? "Grave" }
    public var resolvedFreeCursor: String { freeCursorKey ?? "Alt" }

    public static func load(_ url: URL) throws -> Keymap {
        try decode(Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> Keymap {
        try JSONDecoder().decode(Keymap.self, from: data)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    /// Human-readable problems; empty when the keymap is usable.
    public func validate() -> [String] {
        var problems: [String] = []
        var seen: [String: Int] = [:]
        if controls.filter({ if case .look = $0 { return true }; return false }).count > 1 {
            problems.append("only one look control is allowed")
        }
        for (i, c) in controls.enumerated() {
            let where_ = "control \(i) (\(c.typeName))"
            for p in points(of: c) where !p.isNormalized {
                problems.append("\(where_): point [\(p.x), \(p.y)] is outside 0...1")
            }
            for k in c.keys {
                if !KeyNames.isKnown(k) { problems.append("\(where_): unknown key '\(k)'") }
                let slot = "\(c.mode.rawValue):\(k)"
                if let prev = seen[slot], !jointKey(controls[prev], c, k) {
                    problems.append("\(where_): key '\(k)' already used by control \(prev)")
                }
                seen[slot] = i
            }
            switch c {
            case .joystick(let j):
                if j.radius <= 0 || j.radius > 0.5 { problems.append("\(where_): radius must be in (0, 0.5]") }
                if j.stick == nil && [j.up, j.down, j.left, j.right].allSatisfy({ $0 == nil }) {
                    problems.append("\(where_): needs direction keys or a stick")
                }
            case .look(let l):
                if l.radius <= 0 || l.radius > 0.5 { problems.append("\(where_): radius must be in (0, 0.5]") }
                if l.sensitivity <= 0 { problems.append("\(where_): sensitivity must be > 0") }
            case .turbo(let t):
                if t.intervalMs < 20 { problems.append("\(where_): intervalMs must be >= 20") }
            case .swipe(let s):
                if s.durationMs < 10 { problems.append("\(where_): durationMs must be >= 10") }
            case .combo(let c):
                if c.points.isEmpty { problems.append("\(where_): needs at least one point") }
                if c.intervalMs < 20 { problems.append("\(where_): intervalMs must be >= 20") }
            case .macro(let m):
                do { _ = try MacroScript.parse(m.script) } catch { problems.append("\(where_): \(error)") }
            default: break
            }
        }
        return problems
    }

    private func jointKey(_ a: Control, _ b: Control, _ key: String) -> Bool {
        // A look scope key may double as a tap (e.g. right mouse = scope + ADS button).
        if case .look = a { return true }
        if case .look = b { return true }
        return false
    }

    private func points(of c: Control) -> [NPoint] {
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
