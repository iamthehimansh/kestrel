import AppKit
import KestrelCore
import KestrelKeymap

/// Apps, Google Play and snapshots.
extension AppModel {
    func packages(_ i: Int, done: @escaping ([String]) -> Void) {
        guard let adb = adb(i) else { return done([]) }
        work.async {
            let list = (try? adb.packages()) ?? []
            DispatchQueue.main.async { done(list) }
        }
    }

    func installAPK(_ i: Int, _ url: URL, done: (() -> Void)? = nil) {
        guard let adb = adb(i) else { return }
        guard state(i) == .running else { errorMessage = "Start the instance before installing apps."; return }
        perform(i, "Installing \(url.lastPathComponent)…", { try adb.install(url.path) }) { _ in
            self.notice = "Installed \(url.lastPathComponent)"
            done?()
        }
    }

    func launchApp(_ i: Int, _ package: String) {
        guard let adb = adb(i) else { return }
        perform(i, "Opening \(package)…") { _ = try adb.launch(package) }
    }

    func stopApp(_ i: Int, _ package: String) {
        guard let adb = adb(i) else { return }
        perform(i, "Closing \(package)…") { _ = try adb.forceStop(package) }
    }

    func uninstallApp(_ i: Int, _ package: String, done: (() -> Void)? = nil) {
        guard let adb = adb(i) else { return }
        perform(i, "Uninstalling \(package)…", { _ = try adb.uninstall(package) }) { _ in done?() }
    }

    func openPlayStore(_ i: Int, package: String? = nil) {
        guard let adb = adb(i) else { return }
        let pkg = package?.trimmingCharacters(in: .whitespaces) ?? ""
        perform(i, "Opening Google Play…") {
            if pkg.isEmpty {
                _ = try adb.launch("com.android.vending")
            } else {
                _ = try adb.shell("am start -a android.intent.action.VIEW -d \(shellQuote("market://details?id=\(pkg)")) com.android.vending")
            }
        }
    }

    /// The keymap made for an Android package, if one exists.
    func keymapEntry(forPackage package: String) -> KeymapLibrary.Entry? {
        keymaps.first { $0.keymap.package == package }
    }

    /// Opens a game and turns key mapping on with its keymap: one click, like MuMu.
    func play(_ i: Int, _ package: String) {
        guard let adb = adb(i) else { return }
        let entry = keymapEntry(forPackage: package)
        perform(i, "Opening \(package)…", { _ = try adb.launch(package) }) { _ in
            guard let entry else { return }
            if self.instance(i)?.settings.keymap != entry.id { self.assignKeymap(i, id: entry.id) }
            self.stopKeymapping(i)
            self.startKeymapping(i)
        }
    }

    // MARK: - Snapshots

    func snapshots(_ i: Int) -> [Snapshot] {
        guard let store else { return [] }
        return Snapshots(store: store).list(i)
    }

    func saveSnapshot(_ i: Int, name: String, done: (() -> Void)? = nil) {
        guard let store else { return }
        let snaps = Snapshots(store: store)
        perform(i, "Saving “\(name)”…", { try snaps.save(i, name: name) }) { _ in
            self.notice = "Saved “\(name)”"
            done?()
        }
    }

    func restoreSnapshot(_ i: Int, name: String) {
        guard let store else { return }
        let snaps = Snapshots(store: store)
        stopKeymapping(i)
        perform(i, "Restoring “\(name)”…") { try snaps.load(i, name: name) }
    }

    func deleteSnapshot(_ i: Int, name: String, done: (() -> Void)? = nil) {
        guard let store else { return }
        let snaps = Snapshots(store: store)
        perform(i, "Deleting “\(name)”…", { try snaps.delete(i, name: name) }) { _ in done?() }
    }
}
