import Foundation

/// A saved Android state ("save state" in console terms): RAM, CPU and disks, resumable in
/// seconds. Uses the emulator's own snapshot support, stored inside the instance's AVD.
public struct Snapshot: Equatable, Sendable {
    public let name: String
    public let date: Date?
    public let sizeBytes: Int64
}

public struct Snapshots {
    public let store: InstanceStore

    public init(store: InstanceStore) { self.store = store }

    /// The emulator keeps its automatic quick-boot state under this name.
    public static let quickBoot = "default_boot"

    /// Snapshot names must be safe as a single path component and a console argument.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name != quickBoot
            && name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    }

    func dir(_ index: Int) -> URL { store.paths.avdDir(index).appendingPathComponent("snapshots") }

    /// Lists snapshots from disk, so it works whether or not the instance is running.
    /// The automatic quick-boot state is left out unless `includeQuickBoot` is set.
    public func list(_ index: Int, includeQuickBoot: Bool = false) -> [Snapshot] {
        let fm = FileManager.default
        let base = dir(index)
        let names = (try? fm.contentsOfDirectory(atPath: base.path)) ?? []
        return names.compactMap { name -> Snapshot? in
            guard includeQuickBoot || name != Self.quickBoot else { return nil }
            let d = base.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: d.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let files = (try? fm.contentsOfDirectory(atPath: d.path)) ?? []
            guard !files.isEmpty else { return nil }
            var size: Int64 = 0
            var newest: Date?
            for f in files {
                let attrs = try? fm.attributesOfItem(atPath: d.appendingPathComponent(f).path)
                size += (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                if let m = attrs?[.modificationDate] as? Date, newest.map({ m > $0 }) ?? true { newest = m }
            }
            return Snapshot(name: name, date: newest, sizeBytes: size)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    private func console(_ index: Int, _ args: [String]) throws -> String {
        let inst = try store.load(index)
        guard Launcher(store: store).runningPID(index) != nil else {
            throw KestrelError.runtime("instance \(index) is not running")
        }
        let out = try ADB(sdk: store.sdk, serial: inst.ports.serial).run(["emu"] + args)
        // The console reports failures as "KO: ..." on stdout with exit status 0.
        if let ko = out.split(separator: "\n").first(where: { $0.hasPrefix("KO") }) {
            throw KestrelError.runtime("emulator: \(ko)")
        }
        return out
    }

    /// Saves the running instance's current state under `name` (replacing one with that name).
    public func save(_ index: Int, name: String) throws {
        guard Self.isValidName(name) else {
            throw KestrelError.invalid("snapshot names use letters, digits, '.', '_' and '-' (max 64), and '\(Self.quickBoot)' is reserved")
        }
        _ = try console(index, ["avd", "snapshot", "save", name])
        guard list(index).contains(where: { $0.name == name }) else {
            throw KestrelError.runtime("the emulator reported success but snapshot '\(name)' is not on disk")
        }
    }

    /// Restores a snapshot into the running instance.
    public func load(_ index: Int, name: String) throws {
        guard list(index).contains(where: { $0.name == name }) else { throw KestrelError.notFound("snapshot '\(name)'") }
        _ = try console(index, ["avd", "snapshot", "load", name])
    }

    /// Deletes a snapshot; works while stopped.
    public func delete(_ index: Int, name: String) throws {
        guard Self.isValidName(name) else { throw KestrelError.invalid("not a deletable snapshot name: \(name)") }
        let d = dir(index).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: d.path) else { throw KestrelError.notFound("snapshot '\(name)'") }
        if Launcher(store: store).runningPID(index) != nil {
            _ = try? console(index, ["avd", "snapshot", "delete", name])
        }
        if FileManager.default.fileExists(atPath: d.path) { try FileManager.default.removeItem(at: d) }
    }
}
