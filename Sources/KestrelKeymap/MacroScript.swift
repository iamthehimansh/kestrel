import Foundation

/// A small line-based macro language. Coordinates are normalized (0...1).
///
///     # comment
///     tap 0.5 0.5                 # quick tap (advances 40 ms)
///     press A 0.2 0.8             # put finger "A" down
///     move A 0.3 0.8              # move finger "A"
///     release A                   # lift finger "A"
///     swipe 0.1 0.5 0.6 0.5 200   # swipe over 200 ms (advances 200 ms)
///     wait 50                     # pause 50 ms
///     repeat 3                    # repeat the block
///       tap 0.9 0.9
///       wait 30
///     end
///
/// Fingers still down at the end of the script are lifted automatically.
public enum MacroScript {
    public enum Instr: Equatable, Sendable {
        case press(String, NPoint)
        case move(String, NPoint)
        case release(String)
        case tap(NPoint)
        case swipe(NPoint, NPoint, Double)
        case wait(Double)
        case repeatBlock(Int, [Instr])
    }

    public enum Action: Equatable, Sendable {
        case press(NPoint), move(NPoint), release
    }

    /// One compiled step: at `t` ms from start, finger `finger` does `action`.
    public struct Step: Equatable, Sendable {
        public let t: Double
        public let finger: String
        public let action: Action
    }

    public struct ParseError: Error, CustomStringConvertible, Equatable {
        public let line: Int
        public let message: String
        public var description: String { "macro line \(line): \(message)" }
    }

    public static let tapHoldMs = 40.0
    public static let maxSteps = 20_000

    public static func parse(_ source: String) throws -> [Instr] {
        let lines = source.components(separatedBy: .newlines).enumerated().map { (n: $0.offset + 1, text: $0.element) }
        var pos = 0
        let block = try parseBlock(lines, &pos, nested: false)
        return block
    }

    private static func parseBlock(_ lines: [(n: Int, text: String)], _ pos: inout Int, nested: Bool) throws -> [Instr] {
        var out: [Instr] = []
        while pos < lines.count {
            let (n, raw) = lines[pos]
            pos += 1
            let text = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let tok = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," }).map(String.init)
            guard let cmd = tok.first?.lowercased() else { continue }
            let args = Array(tok.dropFirst())

            func num(_ i: Int) throws -> Double {
                guard i < args.count, let v = Double(args[i]) else {
                    throw ParseError(line: n, message: "'\(cmd)' expects a number as argument \(i + 1)")
                }
                return v
            }
            func point(_ i: Int) throws -> NPoint {
                let p = NPoint(try num(i), try num(i + 1))
                guard p.isNormalized else { throw ParseError(line: n, message: "coordinates must be within 0...1") }
                return p
            }
            func arity(_ k: Int) throws {
                if args.count != k { throw ParseError(line: n, message: "'\(cmd)' takes \(k) argument(s), got \(args.count)") }
            }
            func finger() throws -> String {
                guard let f = args.first, Double(f) == nil else {
                    throw ParseError(line: n, message: "'\(cmd)' needs a finger name first, e.g. '\(cmd) A ...'")
                }
                return f
            }

            switch cmd {
            case "tap": try arity(2); out.append(.tap(try point(0)))
            case "press", "down":
                try arity(3); let f = try finger(); out.append(.press(f, NPoint(try num(1), try num(2))))
                if case .press(_, let p) = out.last!, !p.isNormalized { throw ParseError(line: n, message: "coordinates must be within 0...1") }
            case "move":
                try arity(3); let f = try finger(); let p = NPoint(try num(1), try num(2))
                guard p.isNormalized else { throw ParseError(line: n, message: "coordinates must be within 0...1") }
                out.append(.move(f, p))
            case "release", "up": try arity(1); out.append(.release(try finger()))
            case "swipe":
                try arity(5)
                let d = try num(4)
                guard d >= 1 else { throw ParseError(line: n, message: "swipe duration must be >= 1 ms") }
                out.append(.swipe(try point(0), try point(2), d))
            case "wait", "sleep":
                try arity(1)
                let d = try num(0)
                guard d >= 0 else { throw ParseError(line: n, message: "wait must be >= 0") }
                out.append(.wait(d))
            case "repeat":
                try arity(1)
                guard let k = Int(args[0]), (1...1000).contains(k) else { throw ParseError(line: n, message: "repeat count must be 1-1000") }
                let body = try parseBlock(lines, &pos, nested: true)
                out.append(.repeatBlock(k, body))
            case "end":
                if !nested { throw ParseError(line: n, message: "'end' without 'repeat'") }
                return out
            default:
                throw ParseError(line: n, message: "unknown command '\(cmd)'")
            }
        }
        if nested { throw ParseError(line: lines.count, message: "'repeat' without 'end'") }
        return out
    }

    /// Flattens instructions into timed finger steps.
    public static func compile(_ program: [Instr]) throws -> (steps: [Step], duration: Double) {
        var steps: [Step] = []
        var t = 0.0
        var down: [String: NPoint] = [:]
        var tmp = 0

        func emit(_ f: String, _ a: Action) throws {
            steps.append(Step(t: t, finger: f, action: a))
            if steps.count > maxSteps { throw ParseError(line: 0, message: "macro expands to more than \(maxSteps) steps") }
        }

        func run(_ instrs: [Instr]) throws {
            for i in instrs {
                switch i {
                case .press(let f, let p):
                    if down[f] != nil { try emit(f, .release) }
                    try emit(f, .press(p)); down[f] = p
                case .move(let f, let p):
                    if down[f] == nil { try emit(f, .press(p)) } else { try emit(f, .move(p)) }
                    down[f] = p
                case .release(let f):
                    if down[f] != nil { try emit(f, .release); down[f] = nil }
                case .tap(let p):
                    tmp += 1
                    let f = "#t\(tmp)"
                    try emit(f, .press(p)); t += tapHoldMs; try emit(f, .release)
                case .swipe(let a, let b, let d):
                    tmp += 1
                    let f = "#s\(tmp)"
                    try emit(f, .press(a))
                    let n = max(2, Int(d / 16))
                    let start = t
                    for k in 1...n {
                        let u = Double(k) / Double(n)
                        t = start + d * u
                        try emit(f, .move(NPoint(a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u)))
                    }
                    try emit(f, .release)
                case .wait(let d): t += d
                case .repeatBlock(let k, let body):
                    for _ in 0..<k { try run(body) }
                }
            }
        }
        try run(program)
        for f in down.keys.sorted() { try emit(f, .release) }
        return (steps, t)
    }
}
