import Foundation

extension InputEvent {
    /// Text form used by recordings and `kestrel keymap simulate`:
    /// keydown:W keyup:W mouse:dx,dy cursor:x,y wheel:n stick:left,x,y look:on|off reset
    public var token: String {
        switch self {
        case .keyDown(let k): return "keydown:\(k)"
        case .keyUp(let k): return "keyup:\(k)"
        case .mouseMove(let dx, let dy): return "mouse:\(fmt(dx)),\(fmt(dy))"
        case .cursor(let p): return "cursor:\(fmt(p.x)),\(fmt(p.y))"
        case .pointerDown(let p): return "pointerdown:\(fmt(p.x)),\(fmt(p.y))"
        case .pointerMove(let p): return "pointermove:\(fmt(p.x)),\(fmt(p.y))"
        case .pointerUp: return "pointerup"
        case .wheel(let n): return "wheel:\(fmt(n))"
        case .stick(let name, let x, let y): return "stick:\(name),\(fmt(x)),\(fmt(y))"
        case .setLook(let on): return "look:\(on ? "on" : "off")"
        case .reset: return "reset"
        }
    }

    public init?(token: String) {
        if token == "reset" { self = .reset; return }
        if token == "pointerup" { self = .pointerUp; return }
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let fields = parts[1].split(separator: ",").map(String.init)
        let nums = fields.compactMap(Double.init)
        switch parts[0] {
        case "keydown": self = .keyDown(parts[1])
        case "keyup": self = .keyUp(parts[1])
        case "mouse": guard nums.count == 2, fields.count == 2 else { return nil }; self = .mouseMove(dx: nums[0], dy: nums[1])
        case "cursor": guard nums.count == 2, fields.count == 2 else { return nil }; self = .cursor(NPoint(nums[0], nums[1]))
        case "pointerdown", "pointermove":
            guard nums.count == 2, fields.count == 2, nums.allSatisfy({ $0.isFinite }) else { return nil }
            let point = NPoint(nums[0], nums[1])
            self = parts[0] == "pointerdown" ? .pointerDown(point) : .pointerMove(point)
        case "wheel": guard nums.count == 1, fields.count == 1 else { return nil }; self = .wheel(nums[0])
        case "stick":
            guard fields.count == 3, let x = Double(fields[1]), let y = Double(fields[2]) else { return nil }
            self = .stick(name: fields[0], x: x, y: y)
        case "look":
            guard parts[1] == "on" || parts[1] == "off" else { return nil }
            self = .setLook(parts[1] == "on")
        default: return nil
        }
    }
}

private func fmt(_ v: Double) -> String {
    v == v.rounded() && abs(v) < 1e9 ? String(Int(v)) : String(format: "%.4f", v)
}

/// A recorded input session: timed host events, replayable through any engine.
/// File format: one "<ms> <token>" line per event, '#' comments allowed.
public struct InputRecording: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let t: Double
        public let event: InputEvent
        public init(t: Double, event: InputEvent) { self.t = t; self.event = event }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    public var duration: Double { entries.last?.t ?? 0 }

    public func serialized() -> String {
        "# Kestrel input recording v1\n" + entries.map { String(format: "%.1f", $0.t) + " " + $0.event.token }.joined(separator: "\n") + "\n"
    }

    public static func parse(_ text: String) throws -> InputRecording {
        var out: [Entry] = []
        var last = 0.0
        for (n, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let f = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard f.count == 2, let t = Double(f[0]), let ev = InputEvent(token: f[1]) else {
                throw MacroScript.ParseError(line: n + 1, message: "expected '<ms> <event>', got '\(line)'")
            }
            guard t >= last else { throw MacroScript.ParseError(line: n + 1, message: "time goes backwards") }
            last = t
            out.append(Entry(t: t, event: ev))
        }
        return InputRecording(entries: out)
    }

    /// Feeds the recording through `engine`, ticking every `tickMs` between events, and
    /// returns every touch op with its time. Deterministic: the same recording always
    /// yields the same ops.
    public func replay(through engine: KeymapEngine, tickMs: Double = 8, tail: Double = 1000) -> [(t: Double, op: TouchOp)] {
        var out: [(Double, TouchOp)] = []
        var t = 0.0
        for e in entries {
            while t + tickMs < e.t {
                t += tickMs
                out += engine.tick(at: t).map { (t, $0) }
            }
            t = e.t
            out += engine.handle(e.event, at: t).map { (t, $0) }
        }
        let end = t + tail
        while t < end {
            t += tickMs
            out += engine.tick(at: t).map { (t, $0) }
        }
        out += engine.handle(.reset, at: t).map { (t, $0) }
        return out
    }
}

/// Thread-safe recorder that timestamps events relative to its creation.
public final class InputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [InputRecording.Entry] = []
    private let start: UInt64

    public init(clock: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        start = clock()
    }

    public func record(_ event: InputEvent, nanos: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        let t = Double(nanos &- start) / 1_000_000
        lock.lock()
        entries.append(.init(t: max(t, entries.last?.t ?? 0), event: event))
        lock.unlock()
    }

    public var recording: InputRecording {
        lock.lock()
        defer { lock.unlock() }
        return InputRecording(entries: entries)
    }
}
