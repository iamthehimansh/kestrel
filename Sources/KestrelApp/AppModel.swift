import AppKit
import SwiftUI
import KestrelCore
import KestrelKeymap
import KestrelPlay

enum RunState: Equatable {
    case stopped, booting, running
}

/// Everything the window shows, plus every action. Lives on the main thread; slow work
/// (booting, adb, snapshots) runs on `work` and reports back on main.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var sdkReady = false
    @Published var instances: [Instance] = []
    @Published var states: [Int: RunState] = [:]
    @Published var selection: Int? { didSet { if selection != oldValue { selectionChanged() } } } // selectionChanged: AppModel+Play.swift
    @Published var busy: [Int: String] = [:]
    @Published var errorMessage: String?
    @Published var notice: String?

    @Published var showNewInstance = false
    @Published var renaming: Int?
    @Published var deleting: Int?

    @Published var activeSessions: Set<Int> = []
    @Published var recordingSessions: Set<Int> = []
    @Published var sessionStatus: [Int: String] = [:]
    @Published var keymaps: [KeymapLibrary.Entry] = []

    @Published var editingKeymapID: String?
    @Published var editingKeymap: Keymap?
    @Published var keymapDirty = false
    @Published var selectedControl: Int?
    @Published var screenshot: NSImage?

    let paths = KestrelPaths()
    let library: KeymapLibrary
    private(set) var store: InstanceStore?
    /// Live key-mapping sessions by instance (managed in AppModel+Play.swift).
    var sessions: [Int: KeymapSession] = [:]
    private var booting: Set<Int> = []
    private var poll: Timer?
    let work = DispatchQueue(label: "kestrel.app.work", qos: .userInitiated, attributes: .concurrent)

    init() {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        library = KeymapLibrary(userDir: paths.keymaps,
                                bundledDirs: KeymapLibrary.bundledDirs(executable: exe,
                                                                       cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
        connectSDK()
        reloadKeymaps()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshStates() }
    }

    // MARK: - SDK

    func connectSDK() {
        let root = SDKSetup.sdkRoot()
        let ready = SDKSetup.components.filter(\.required).allSatisfy { SDKSetup.isInstalled($0.package, root: root) }
        if ready {
            store = InstanceStore(paths: paths, sdk: AndroidSDK(root: root))
        } else if let sdk = try? AndroidSDK.locate(), sdk.hasSystemImage(SDKSetup.defaultImage),
                  FileManager.default.isExecutableFile(atPath: sdk.adb.path) {
            store = InstanceStore(paths: paths, sdk: sdk)
        } else {
            store = nil
        }
        sdkReady = store != nil
        if sdkReady { reload() }
    }

    func installSDK(log: @escaping (String) -> Void, done: @escaping (Bool) -> Void) {
        let root = SDKSetup.sdkRoot()
        work.async {
            var ok = true
            do {
                try SDKSetup.install(root: root, includeOptional: false) { line in DispatchQueue.main.async { log(line) } }
            } catch {
                ok = false
                DispatchQueue.main.async { log("Failed: \(error)") }
            }
            DispatchQueue.main.async {
                self.connectSDK()
                done(ok && self.sdkReady)
            }
        }
    }

    // MARK: - Instances

    func instance(_ i: Int) -> Instance? { instances.first { $0.index == i } }

    func state(_ i: Int) -> RunState { states[i] ?? .stopped }

    func reload() {
        guard let store else { return }
        instances = (try? store.list()) ?? []
        if let s = selection, !instances.contains(where: { $0.index == s }) { selection = nil }
        if selection == nil { selection = instances.first?.index }
        refreshStates()
    }

    func refreshStates() {
        guard let store else { return }
        let launcher = Launcher(store: store)
        var next: [Int: RunState] = [:]
        for inst in instances {
            if launcher.runningPID(inst.index) == nil {
                next[inst.index] = booting.contains(inst.index) ? .booting : .stopped
                if sessions[inst.index] != nil { stopKeymapping(inst.index) }
            } else {
                next[inst.index] = booting.contains(inst.index) ? .booting : .running
            }
        }
        if next != states { states = next }
    }

    /// Runs `job` off the main thread with a busy label, then reports errors and refreshes.
    func perform<T>(_ i: Int?, _ label: String, _ job: @escaping () throws -> T, then: ((T) -> Void)? = nil) {
        if let i { busy[i] = label }
        work.async {
            let result = Result { try job() }
            DispatchQueue.main.async {
                if let i { self.busy[i] = nil }
                switch result {
                case .success(let v): then?(v)
                case .failure(let e): self.errorMessage = "\(e)"
                }
                self.reload()
            }
        }
    }

    func create(name: String, preset: PerformancePreset, resolution: String?) {
        guard let store else { return }
        do {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            let inst = try store.create(name: trimmed.isEmpty ? nil : trimmed, preset: preset, resolution: resolution)
            reload()
            selection = inst.index
        } catch { errorMessage = "\(error)" }
    }

    func clone(_ i: Int) {
        guard let store else { return }
        do { let inst = try store.clone(i); reload(); selection = inst.index } catch { errorMessage = "\(error)" }
    }

    func rename(_ i: Int, to name: String) {
        guard let store else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            var inst = try store.load(i)
            inst.settings.name = trimmed
            try store.save(inst)
            reload()
        } catch { errorMessage = "\(error)" }
    }

    func delete(_ i: Int) {
        guard let store else { return }
        guard state(i) == .stopped else { errorMessage = "Stop the instance before deleting it."; return }
        do { try store.delete(i); reload() } catch { errorMessage = "\(error)" }
    }

    func saveSettings(_ i: Int, _ settings: InstanceSettings) {
        guard let store else { return }
        do {
            var inst = try store.load(i)
            inst.settings = settings
            try store.save(inst)
            reload()
            notice = state(i) == .stopped ? "Settings saved." : "Settings saved. Restart the instance to apply them."
        } catch { errorMessage = "\(error)" }
    }

    /// Boots (resuming the last state), cold boots, or resumes a saved snapshot.
    func start(_ i: Int, cold: Bool = false, snapshot: String? = nil) {
        guard let store else { return }
        let launcher = Launcher(store: store)
        booting.insert(i)
        busy[i] = snapshot.map { "Resuming “\($0)”…" } ?? (cold ? "Cold booting…" : "Starting…")
        states[i] = .booting
        work.async {
            let result = Result {
                try launcher.start(i, coldBoot: cold, snapshot: snapshot)
                try launcher.waitForBoot(i)
            }
            DispatchQueue.main.async {
                self.booting.remove(i)
                self.busy[i] = nil
                if case .failure(let e) = result { self.errorMessage = "\(e)" }
                self.reload()
            }
        }
    }

    func stop(_ i: Int) {
        guard let store else { return }
        stopKeymapping(i)
        let launcher = Launcher(store: store)
        perform(i, "Stopping…") { try launcher.stop(i) }
    }

    func startAll() { for inst in instances where state(inst.index) == .stopped { start(inst.index) } }

    func stopAll() { for inst in instances where state(inst.index) == .running { stop(inst.index) } }

    func adb(_ i: Int) -> ADB? {
        guard let store, let inst = instance(i) else { return nil }
        return ADB(sdk: store.sdk, serial: inst.ports.serial)
    }

    func saveScreenshot(_ i: Int) {
        guard let adb = adb(i) else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop/Kestrel \(fmt.string(from: Date())).png")
        perform(i, "Taking screenshot…", { try adb.screenshot(to: url.path) }) { _ in
            self.notice = "Screenshot saved to the Desktop"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
