import CryptoKit
import Foundation

/// Conservative parser for Android's current InputMethodManager client section.
/// The caller must also verify the focused guest window and never log the raw dump.
public struct PlayerGuestTextFocus: Equatable, Sendable {
    public let editorID: String
    public let packageName: String

    /// Samples are not atomic. A changed window invalidates the observation even if
    /// both windows belong to the same package; freshness is enforced by the caller.
    public static func validated(inputMethodDump: String, windowBefore: String, windowAfter: String) -> Self? {
        guard let before = focusedWindowLine(windowBefore),
              before == focusedWindowLine(windowAfter) else { return nil }
        return validated(inputMethodDump: inputMethodDump, windowDump: windowAfter)
    }

    private static func focusedWindowLine(_ dump: String) -> String? {
        guard dump.utf8.count <= 1_048_576 else { return nil }
        let lines = dump.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("mCurrentFocus=") }
        return lines.count == 1 ? lines.first : nil
    }

    public static func validated(inputMethodDump: String, windowDump: String) -> Self? {
        guard let editor = parse(inputMethodDump), windowDump.utf8.count <= 1_048_576 else { return nil }
        let focusLines = windowDump.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("mCurrentFocus=") }
        guard focusLines.count == 1, let line = focusLines.first,
              let regex = try? NSRegularExpression(pattern: #"^mCurrentFocus=Window\{[0-9a-fA-F]+ u[0-9]+ ([A-Za-z0-9_.]+)/[^\s}]+\}$"#),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              (line as NSString).substring(with: match.range(at: 1)) == editor.packageName else { return nil }
        return editor
    }

    public static func parse(_ dump: String) -> Self? {
        guard dump.utf8.count <= 1_048_576 else { return nil }
        let lines = dump.components(separatedBy: .newlines)
        let headers = lines.indices.filter { lines[$0].hasPrefix("Input method client state for ") }
        guard headers.count == 1, let start = headers.first else { return nil }
        var fields: [String: String] = [:]
        var editorLines: [String] = []
        var inEditor = false
        for line in lines.dropFirst(start + 1) {
            if !line.isEmpty && !line.hasPrefix(" ") { break }
            if line.hasPrefix("  mCurrentEditorInfo:") {
                guard fields["editor"] == nil else { return nil }
                fields["editor"] = line
                inEditor = line == "  mCurrentEditorInfo:"
                continue
            }
            if inEditor && line.hasPrefix("    ") {
                editorLines.append(line)
                continue
            }
            inEditor = false
            for key in ["mActive", "mServedView", "mServedConnecting", "mServedInputConnection"] {
                let prefix = "  \(key)="
                if line.hasPrefix(prefix) {
                    guard fields[key] == nil else { return nil }
                    fields[key] = String(line.dropFirst(prefix.count))
                }
            }
        }
        guard fields["mActive"]?.split(separator: " ").first == "true",
              fields["mServedConnecting"] == "false",
              let view = fields["mServedView"], view != "null", view.utf8.count <= 512,
              let connection = fields["mServedInputConnection"],
              connection.hasPrefix("RemoteInputConnectionImpl{"),
              connection.contains("mDeactivateRequested=false"),
              connection.contains("mServedView=\(view)}") else { return nil }
        func matches(_ pattern: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return editorLines.flatMap { line -> [String] in
                let ns = line as NSString
                return regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
                    .map { ns.substring(with: $0.range(at: 1)) }
            }
        }
        let types = matches(#"^    inputType=0x([0-9a-fA-F]+)\b"#)
        let packages = matches(#"\bpackageName=([a-zA-Z0-9_.]+)\b"#)
        guard types.count == 1, let raw = UInt32(types[0], radix: 16),
              (1...4).contains(raw & 0xf), packages.count == 1,
              packages[0].contains("."), packages[0].utf8.count <= 256 else { return nil }
        // Hash only structural identity. Do not include editor contents or selection text.
        let identity = packages[0] + "\n" + view + "\n" + connection
        let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return Self(editorID: hash, packageName: packages[0])
    }
}
