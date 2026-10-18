import Foundation

public struct PlayerDisplayOrientation: Equatable, Sendable {
    public let rotation: PlayerRotation
    public let width: Int
    public let height: Int

    public static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 1_048_576 else { throw KestrelError.invalid("Input viewport evidence exceeds limit") }
        let pattern = #"Viewport INTERNAL: displayId=0,.*?orientation=([0-3]), logicalFrame=\[0, 0, ([0-9]+), ([0-9]+)\].*?isActive=\[1\]"#
        let expression = try NSRegularExpression(pattern: pattern)
        var result: Self?
        for line in text.components(separatedBy: .newlines)
            where line.contains("Viewport INTERNAL: displayId=0,") && line.contains("isActive=[1]") {
            let ns = line as NSString
            guard let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  let raw = Int(ns.substring(with: match.range(at: 1))), let rotation = PlayerRotation(rawValue: raw),
                  let width = Int(ns.substring(with: match.range(at: 2))),
                  let height = Int(ns.substring(with: match.range(at: 3))),
                  (1...PlayerFrame.maximumDimension).contains(width),
                  (1...PlayerFrame.maximumDimension).contains(height) else {
                throw KestrelError.invalid("Malformed active input viewport")
            }
            let candidate = Self(rotation: rotation, width: width, height: height)
            guard result == nil || result == candidate else { throw KestrelError.invalid("Conflicting active input viewports") }
            result = candidate
        }
        guard let result else { throw KestrelError.runtime("No active primary input viewport") }
        return result
    }
}
