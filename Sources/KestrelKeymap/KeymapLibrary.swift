import Foundation

/// Where keymaps come from: the user's own folder first (edits live there), then the
/// bundled presets. A user keymap with the same file name overrides the bundled one.
public struct KeymapLibrary: Sendable {
    public struct Entry: Equatable, Sendable {
        /// File name without ".json"; the id used everywhere else.
        public let id: String
        public let url: URL
        public let keymap: Keymap
        /// True when it lives in the user folder (editable in place).
        public let isUser: Bool
    }

    public let userDir: URL
    public let bundledDirs: [URL]

    public init(userDir: URL, bundledDirs: [URL]) {
        self.userDir = userDir
        self.bundledDirs = bundledDirs
    }

    /// Bundled keymap folders for a program running at `executable`: inside an app bundle
    /// (Contents/Resources/keymaps), next to a CLI binary, or in the source tree.
    public static func bundledDirs(executable: URL, cwd: URL) -> [URL] {
        let exe = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        return [
            exe.appendingPathComponent("../Resources/keymaps").standardized,
            exe.appendingPathComponent("keymaps"),
            exe.appendingPathComponent("../share/kestrel/keymaps").standardized,
            exe.appendingPathComponent("../../keymaps").standardized,
            exe.appendingPathComponent("../../../keymaps").standardized,
            cwd.appendingPathComponent("keymaps"),
        ]
    }

    public static func idOK(_ id: String) -> Bool {
        id.count <= 64 && id.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil
    }

    /// Every loadable keymap, user ones first; unreadable files are skipped.
    public func all() -> [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        let fm = FileManager.default
        for (dir, isUser) in [(userDir, true)] + bundledDirs.map({ ($0, false) }) {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension == "json" {
                let id = f.deletingPathExtension().lastPathComponent
                guard !seen.contains(id), let km = try? Keymap.load(f) else { continue }
                seen.insert(id)
                out.append(Entry(id: id, url: f, keymap: km, isUser: isUser))
            }
        }
        return out
    }

    /// Finds a keymap by file path, id, or Android package name.
    public func resolve(_ ref: String) throws -> Entry {
        let direct = URL(fileURLWithPath: ref)
        if ref.contains("/") || ref.hasSuffix(".json"), FileManager.default.fileExists(atPath: direct.path) {
            let km = try Keymap.load(direct)
            let isUser = direct.standardized.path.hasPrefix(userDir.standardized.path)
            return Entry(id: direct.deletingPathExtension().lastPathComponent, url: direct, keymap: km, isUser: isUser)
        }
        let id = ref.hasSuffix(".json") ? String(ref.dropLast(5)) : ref
        let entries = all()
        if let hit = entries.first(where: { $0.id == id }) ?? entries.first(where: { $0.keymap.package == ref }) {
            return hit
        }
        throw KeymapLibraryError.notFound(ref)
    }

    /// Keymap for an Android package, if any names it.
    public func forPackage(_ package: String) -> Entry? {
        all().first { $0.keymap.package == package }
    }

    /// Writes a keymap to the user folder (validated). Bundled presets are never modified.
    @discardableResult
    public func save(_ keymap: Keymap, id: String) throws -> URL {
        guard Self.idOK(id) else { throw KeymapLibraryError.badID(id) }
        let problems = keymap.validate()
        guard problems.isEmpty else { throw KeymapLibraryError.invalid(problems) }
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        let url = userDir.appendingPathComponent("\(id).json")
        try keymap.encoded().write(to: url, options: .atomic)
        return url
    }

    /// Removes a user keymap. If it overrode a bundled one, the bundled one shows again.
    public func deleteUser(id: String) throws {
        guard Self.idOK(id) else { throw KeymapLibraryError.badID(id) }
        let url = userDir.appendingPathComponent("\(id).json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw KeymapLibraryError.notFound(id) }
        try FileManager.default.removeItem(at: url)
    }

    /// A free id based on `base` ("bgmi" -> "bgmi-copy", "bgmi-copy-2", …).
    public func freeID(_ base: String) -> String {
        let taken = Set(all().map(\.id))
        let clean = Self.slug(base)
        if !taken.contains(clean) { return clean }
        var n = 2
        while taken.contains("\(clean)-\(n)") { n += 1 }
        return "\(clean)-\(n)"
    }

    public static func slug(_ s: String) -> String {
        let lowered = s.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let collapsed = lowered.split(separator: "-").joined(separator: "-")
        let trimmed = String(collapsed.prefix(64))
        return trimmed.isEmpty ? "keymap" : trimmed
    }
}

public enum KeymapLibraryError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case badID(String)
    case invalid([String])

    public var description: String {
        switch self {
        case .notFound(let r): return "keymap '\(r)' not found"
        case .badID(let id): return "'\(id)' is not a valid keymap name (lowercase letters, digits and dashes)"
        case .invalid(let p): return "keymap is invalid: " + p.joined(separator: "; ")
        }
    }
}
