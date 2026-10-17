import AppKit
import Foundation
import KestrelCore
import KestrelKeymap
import KestrelPlay

let usage = """
Kestrel: open-source Android gaming emulator for Apple Silicon. No account, no login.

USAGE: kestrel <command> [options]

Setup
  setup [--with-ndk]                     Download the emulator, adb and the Google Play Android image
  setup --check                          Show what is installed

Instances
  list                                   List instances
  create [--name N] [--preset low|medium|high] [--resolution ID]
  clone <i>                              Copy an instance's settings
  delete <i>                             Delete an instance and its data
  info <i>                               Show settings, ports and state
  config <i> [--set '{json}']            Show or change settings (e.g. {"cpuCount":6,"fpsLimit":120})
  rename <i> <name>                      Rename an instance
  start <i> [--cold] [--snapshot NAME] [--wait]
                                         Boot an instance: resumes where it stopped, --cold does a full boot,
                                         --snapshot resumes a saved state (--wait blocks until Android is up)
  stop <i>                               Shut an instance down (its state is kept for the next start)
  snapshot list|save|load|delete <i> [NAME]
                                         Saved states: save the running game, resume it later
  presets                                List resolution and device presets
  images                                 List installed Android system images

Apps (instance must be running)
  install <i> <file.apk>                 Install an APK
  uninstall <i> <package>
  playstore <i> [package]                Open Google Play (optionally on one app's page)
  open <i> <package>                     Launch an app
  close <i> <package>                    Force-stop an app
  apps <i>                               List installed third-party apps
  shell <i> <command...>                 Run an Android shell command
  screenshot <i> <out.png>
  adb <i> <args...>                      Run adb against the instance

Game controls
  play <i> [--keymap FILE|NAME] [--record FILE] [--dry-run]
                                         Map keyboard, mouse and gamepad to touch for a running game
  replay <i> <FILE> [--keymap FILE|NAME] [--dry-run]
                                         Play back a recording made with play --record
  keymap list                            Bundled and saved keymaps
  keymap new <name> [package]            Start a new keymap in KESTREL_HOME/keymaps
  keymap edit <FILE|NAME> [i]            Visual editor (over a live screenshot of instance i)
  keymap show <FILE|NAME>                Print a keymap
  keymap check <FILE|NAME>               Validate a keymap
  keymap simulate <FILE|NAME> <event...> Dry run: print touch ops for events like keydown:W keyup:W
                                         mouse:dx,dy wheel:1 stick:left,x,y cursor:x,y look:on wait:ms
  tap <i> <x> <y>                        Inject one tap (normalized 0-1 coordinates) via touchd

Environment: KESTREL_HOME (data dir), ANDROID_SDK_ROOT, KESTREL_TOUCHD (touchd binary path)
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("kestrel: \(message)\n".utf8))
    exit(1)
}

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: ArraySlice<String>, valued: Set<String>) {
        var it = raw.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if valued.contains(name) {
                    guard let v = it.next() else { fail("--\(name) needs a value") }
                    options[name] = v
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(a)
            }
        }
    }

    func index(_ at: Int = 0) -> Int {
        guard at < positional.count else { fail("missing instance number") }
        guard let i = Int(positional[at]), i >= 0 else { fail("'\(positional[at])' is not an instance number") }
        return i
    }

    func required(_ at: Int, _ what: String) -> String {
        guard at < positional.count else { fail("missing \(what)") }
        return positional[at]
    }
}

func printJSON<T: Encodable>(_ value: T) {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try! e.encode(value), as: UTF8.self))
}

func keymapLibrary(_ paths: KestrelPaths) -> KeymapLibrary {
    KeymapLibrary(userDir: paths.keymaps,
                  bundledDirs: KeymapLibrary.bundledDirs(executable: URL(fileURLWithPath: CommandLine.arguments[0]),
                                                         cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)))
}

func allKeymaps(_ paths: KestrelPaths) -> [(URL, Keymap)] {
    keymapLibrary(paths).all().map { ($0.url, $0.keymap) }
}

func resolveKeymap(_ ref: String, _ paths: KestrelPaths) -> (URL, Keymap) {
    do {
        let e = try keymapLibrary(paths).resolve(ref)
        return (e.url, e.keymap)
    } catch KeymapLibraryError.notFound {
        fail("keymap '\(ref)' not found (try `kestrel keymap list`)")
    } catch {
        fail("cannot read keymap \(ref): \(error)")
    }
}

/// The keymap for play/replay: --keymap, else the instance's saved one. Must validate.
func playKeymap(_ a: Args, _ inst: Instance) throws -> Keymap {
    guard let ref = a.options["keymap"] ?? inst.settings.keymap else {
        fail("no keymap: pass --keymap NAME or set one with config --set '{\"keymap\":\"bgmi\"}'")
    }
    let (url, km) = resolveKeymap(ref, paths)
    let problems = km.validate()
    if !problems.isEmpty { fail("keymap \(url.lastPathComponent) is invalid:\n  " + problems.joined(separator: "\n  ")) }
    return km
}

func parseSimEvent(_ s: String) -> (InputEvent?, Double) {
    let parts = s.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { fail("bad event '\(s)'") }
    let nums = parts[1].split(separator: ",").compactMap { Double($0) }
    switch parts[0] {
    case "keydown": return (.keyDown(parts[1]), 0)
    case "keyup": return (.keyUp(parts[1]), 0)
    case "mouse": guard nums.count == 2 else { fail("mouse:dx,dy") }; return (.mouseMove(dx: nums[0], dy: nums[1]), 0)
    case "cursor": guard nums.count == 2 else { fail("cursor:x,y") }; return (.cursor(NPoint(nums[0], nums[1])), 0)
    case "wheel": guard nums.count == 1 else { fail("wheel:n") }; return (.wheel(nums[0]), 0)
    case "stick":
        let p = parts[1].split(separator: ",").map(String.init)
        guard p.count == 3, let x = Double(p[1]), let y = Double(p[2]) else { fail("stick:left,x,y") }
        return (.stick(name: p[0], x: x, y: y), 0)
    case "look": return (.setLook(parts[1] == "on"), 0)
    case "wait": guard nums.count == 1 else { fail("wait:ms") }; return (nil, nums[0])
    default: fail("unknown event kind '\(parts[0])'")
    }
}

// MARK: - Dispatch

let argv = CommandLine.arguments.dropFirst()
guard let command = argv.first, !["-h", "--help", "help"].contains(command) else {
    print(usage)
    exit(0)
}
let rest = argv.dropFirst()
let paths = KestrelPaths()

func sdkOrFail() -> AndroidSDK {
    do { return try AndroidSDK.locate() } catch { fail("\(error)") }
}

func storeOrFail() -> InstanceStore { InstanceStore(paths: paths, sdk: sdkOrFail()) }

func adbFor(_ i: Int, _ store: InstanceStore) -> ADB {
    do { return ADB(sdk: store.sdk, serial: try store.load(i).ports.serial) } catch { fail("\(error)") }
}

func run(_ body: () throws -> Void) {
    do { try body() } catch { fail("\(error)") }
}

switch command {
case "list":
    let store = storeOrFail()
    let launcher = Launcher(store: store)
    run {
        let list = try store.list()
        if list.isEmpty { print("No instances. Create one with: kestrel create --name Main"); return }
        print(String(format: "%-3@ %-24@ %-9@ %-12@ %-6@ %@", "#", "NAME", "STATE", "RESOLUTION", "CPU", "ADB"))
        for inst in list {
            let s = inst.settings
            let state = launcher.runningPID(inst.index) != nil ? "running" : "stopped"
            print(String(format: "%-3@ %-24@ %-9@ %-12@ %-6@ %@", "\(inst.index)", String(s.name.prefix(24)), state,
                         "\(s.width)x\(s.height)", "\(s.cpuCount)", "127.0.0.1:\(inst.ports.adb)"))
        }
    }

case "create":
    let a = Args(rest, valued: ["name", "preset", "resolution"])
    let store = storeOrFail()
    run {
        let preset = PerformancePreset(rawValue: a.options["preset"] ?? "medium") ?? { fail("preset must be low, medium or high") }()
        let inst = try store.create(name: a.options["name"], preset: preset, resolution: a.options["resolution"])
        if !store.sdk.hasSystemImage(inst.settings.systemImage) {
            print("warning: \(inst.settings.systemImage) is not installed; run: sdkmanager \"\(inst.settings.systemImage)\"")
        }
        print("Created instance \(inst.index) (\(inst.settings.name)): \(inst.settings.cpuCount) CPU, \(inst.settings.memoryMB) MB, \(inst.settings.width)x\(inst.settings.height)")
    }

case "clone":
    let a = Args(rest, valued: [])
    let store = storeOrFail()
    run { let inst = try store.clone(a.index()); print("Cloned to instance \(inst.index)") }

case "delete":
    let a = Args(rest, valued: [])
    let store = storeOrFail()
    run {
        let i = a.index()
        if Launcher(store: store).runningPID(i) != nil { fail("instance \(i) is running; stop it first") }
        try store.delete(i)
        print("Deleted instance \(i)")
    }

case "info":
    let a = Args(rest, valued: [])
    let store = storeOrFail()
    run {
        let inst = try store.load(a.index())
        let pid = Launcher(store: store).runningPID(inst.index)
        print("instance: \(inst.index)\nstate: \(pid.map { "running (pid \($0))" } ?? "stopped")")
        print("adb: 127.0.0.1:\(inst.ports.adb)  serial: \(inst.ports.serial)\nconsole: \(inst.ports.console)")
        print("avd: \(paths.avdDir(inst.index).path)")
        printJSON(inst.settings)
    }

case "config":
    let a = Args(rest, valued: ["set"])
    let store = storeOrFail()
    run {
        var inst = try store.load(a.index())
        if let patch = a.options["set"] {
            inst.settings = try inst.settings.merging(json: Data(patch.utf8))
            try store.save(inst)
            if Launcher(store: store).runningPID(inst.index) != nil { print("saved; restart the instance to apply") }
        }
        printJSON(inst.settings)
    }

case "rename":
    let a = Args(rest, valued: [])
    let store = storeOrFail()
    run {
        var inst = try store.load(a.index())
        let name = a.positional.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { fail("missing new name") }
        inst.settings.name = name
        try store.save(inst)
        print("Renamed instance \(inst.index) to \(name)")
    }

case "snapshot":
    let sub = rest.first ?? "list"
    let a = Args(rest.dropFirst(), valued: [])
    let store = storeOrFail()
    let snaps = Snapshots(store: store)
    run {
        let i = a.index()
        switch sub {
        case "list":
            let list = snaps.list(i)
            if list.isEmpty { print("No snapshots. Save one with: kestrel snapshot save \(i) NAME") }
            let fmt = DateFormatter()
            fmt.dateStyle = .short
            fmt.timeStyle = .short
            for s in list {
                let mb = Double(s.sizeBytes) / 1_048_576
                print("\(s.name)  \(s.date.map(fmt.string(from:)) ?? "-")  \(String(format: "%.0f MB", mb))")
            }
        case "save":
            let name = a.required(1, "snapshot name")
            try snaps.save(i, name: name)
            print("Saved snapshot '\(name)'")
        case "load":
            let name = a.required(1, "snapshot name")
            try snaps.load(i, name: name)
            print("Restored snapshot '\(name)'")
        case "delete":
            let name = a.required(1, "snapshot name")
            try snaps.delete(i, name: name)
            print("Deleted snapshot '\(name)'")
        default:
            fail("unknown snapshot subcommand '\(sub)' (list, save, load, delete)")
        }
    }

case "start":
    let a = Args(rest, valued: ["snapshot"])
    let store = storeOrFail()
    let launcher = Launcher(store: store)
    run {
        let i = a.index()
        let pid = try launcher.start(i, coldBoot: a.flags.contains("cold"), snapshot: a.options["snapshot"])
        print("Instance \(i) started (pid \(pid)), log: \(launcher.logFile(i).path)")
        if a.flags.contains("wait") {
            print("Waiting for Android to boot…")
            try launcher.waitForBoot(i)
            print("Instance \(i) is ready")
        }
    }

case "stop":
    let a = Args(rest, valued: [])
    let store = storeOrFail()
    run { try Launcher(store: store).stop(a.index()); print("Stopped") }

case "presets":
    print("Resolutions:")
    for r in Presets.resolutions { print("  \(r.id)  (\(r.width)x\(r.height) @ \(r.dpi) dpi)") }
    print("Performance (this Mac: \(Host.cores) cores, \(Host.memoryMB) MB):")
    for p in [PerformancePreset.low, .medium, .high] {
        let cm = Presets.cpuMemory(p, hostCores: Host.cores, hostMemoryMB: Host.memoryMB)
        print("  \(p.rawValue): \(cm.cpu) CPU, \(cm.memoryMB) MB")
    }
    print("Device identities (set with config --set '{\"deviceBrand\":…,\"deviceModel\":…}'):")
    for (id, d) in Presets.devices.sorted(by: { $0.key < $1.key }) { print("  \(id): \(d.brand) \(d.model)") }

case "setup":
    let a = Args(rest, valued: [])
    let root = SDKSetup.sdkRoot()
    if a.flags.contains("check") {
        print("Android SDK: \(root.path)")
        var missingRequired = false
        for c in SDKSetup.components {
            let ok = SDKSetup.isInstalled(c.package, root: root)
            if !ok && c.required { missingRequired = true }
            print("  \(ok ? "installed" : (c.required ? "MISSING  " : "optional ")) \(c.package)  (\(c.purpose))")
        }
        if missingRequired { print("Run `kestrel setup` to install what is missing."); exit(1) }
        print("Ready. Create an instance with: kestrel create --name Main")
    } else {
        run {
            try SDKSetup.install(root: root, includeOptional: a.flags.contains("with-ndk")) { print($0) }
            print("Ready. Create an instance with: kestrel create --name Main")
        }
    }

case "playstore":
    let a = Args(rest, valued: [])
    let store = storeOrFail()
    run {
        let inst = try store.load(a.index())
        guard SDKSetup.isPlayImage(inst.settings.systemImage) else {
            fail("instance \(inst.index) uses \(inst.settings.systemImage), which has no Play Store; create one with the default image")
        }
        let adb = adbFor(inst.index, store)
        if let pkg = a.positional.dropFirst().first {
            _ = try adb.shell("am start -a android.intent.action.VIEW -d \(shellQuote("market://details?id=\(pkg)")) com.android.vending")
            print("Opened \(pkg) in the Play Store")
        } else {
            _ = try adb.launch("com.android.vending")
            print("Opened the Play Store. Sign in with your Google account inside Android to install apps.")
        }
    }

case "images":
    let sdk = sdkOrFail()
    let imgs = sdk.installedSystemImages()
    if imgs.isEmpty { print("No system images. Install one: sdkmanager \"system-images;android-36;google_apis_playstore;arm64-v8a\"") }
    imgs.forEach { print($0) }

case "install":
    let a = Args(rest, valued: [])
    let store = storeOrFail()
    run { print(try adbFor(a.index(), store).install(a.required(1, "APK path")), terminator: "") }

case "uninstall":
    let a = Args(rest, valued: [])
    let store = storeOrFail()
    run { print(try adbFor(a.index(), store).uninstall(a.required(1, "package")), terminator: "") }

case "open":
    let a = Args(rest, valued: [])
    let store = storeOrFail()
    run { _ = try adbFor(a.index(), store).launch(a.required(1, "package")); print("Launched \(a.positional[1])") }

case "close":
    let a = Args(rest, valued: [])
    let store = storeOrFail()
    run { _ = try adbFor(a.index(), store).forceStop(a.required(1, "package")); print("Stopped \(a.positional[1])") }

case "apps":
    let a = Args(rest, valued: [])
    let store = storeOrFail()
    run { try adbFor(a.index(), store).packages().forEach { print($0) } }

case "shell":
    let a = Args(rest, valued: [])
    let store = storeOrFail()
    run {
        let cmd = a.positional.dropFirst().joined(separator: " ")
        if cmd.isEmpty { fail("missing shell command") }
        print(try adbFor(a.index(), store).shell(cmd), terminator: "")
    }

case "screenshot":
    let a = Args(rest, valued: [])
    let store = storeOrFail()
    run { let out = a.required(1, "output path"); try adbFor(a.index(), store).screenshot(to: out); print(out) }

case "adb":
    let store = storeOrFail()
    let list = Array(rest)
    guard let first = list.first, let i = Int(first) else { fail("usage: kestrel adb <i> <args...>") }
    run {
        let adb = adbFor(i, store)
        let r = try runProcess(store.sdk.adb, ["-s", adb.serial] + list.dropFirst())
        print(r.stdout, terminator: "")
        FileHandle.standardError.write(Data(r.stderr.utf8))
        exit(r.status)
    }

case "keymap":
    let sub = rest.first ?? "list"
    let a = Args(rest.dropFirst(), valued: [])
    switch sub {
    case "list":
        for (url, km) in allKeymaps(paths) {
            print("\(url.deletingPathExtension().lastPathComponent.padding(toLength: 16, withPad: " ", startingAt: 0)) \(km.package ?? "-")  \(km.name)  [\(km.controls.count) controls]")
        }
    case "show":
        let (_, km) = resolveKeymap(a.required(0, "keymap"), paths)
        run { print(String(decoding: try km.encoded(), as: UTF8.self)) }
    case "check":
        let (url, km) = resolveKeymap(a.required(0, "keymap"), paths)
        let problems = km.validate()
        if problems.isEmpty { print("\(url.lastPathComponent): OK (\(km.controls.count) controls)") }
        else { problems.forEach { print("\(url.lastPathComponent): \($0)") }; exit(1) }
    case "simulate":
        let (_, km) = resolveKeymap(a.required(0, "keymap"), paths)
        let w = Int(ProcessInfo.processInfo.environment["KESTREL_SIM_WIDTH"] ?? "") ?? 1920
        let h = Int(ProcessInfo.processInfo.environment["KESTREL_SIM_HEIGHT"] ?? "") ?? 1080
        let engine = KeymapEngine(keymap: km, screenWidth: w, screenHeight: h)
        var t = 0.0
        for ev in a.positional.dropFirst() {
            let (event, wait) = parseSimEvent(ev)
            if let event {
                for op in engine.handle(event, at: t) { print(String(format: "%7.1f ms  ", t) + op.description) }
            } else {
                let end = t + wait
                while t < end {
                    t = min(end, t + 8)
                    for op in engine.tick(at: t) { print(String(format: "%7.1f ms  ", t) + op.description) }
                }
            }
            t += 1
        }
    case "edit":
        // Bundled presets are never edited in place: edits are saved to KESTREL_HOME/keymaps.
        let (src, km) = resolveKeymap(a.required(0, "keymap"), paths)
        let saveTo: URL
        if src.path.hasPrefix(paths.keymaps.path) {
            saveTo = src
        } else {
            run { try FileManager.default.createDirectory(at: paths.keymaps, withIntermediateDirectories: true) }
            saveTo = paths.keymaps.appendingPathComponent(src.lastPathComponent)
        }
        var background: NSImage?
        var aspect = km.resolvedAspect
        if let i = a.positional.dropFirst().first.flatMap(Int.init) {
            let store = storeOrFail()
            let shot = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-edit-\(i).png")
            do {
                try adbFor(i, store).screenshot(to: shot.path)
                background = NSImage(contentsOf: shot)
                if let b = background, b.size.height > 0 { aspect = b.size.width / b.size.height }
            } catch {
                print("note: no screenshot from instance \(i) (\(error)); editing on a blank canvas")
            }
        }
        print("Editing \(src.lastPathComponent); ⌘S saves to \(saveTo.path)")
        KeymapEditorApp.run(keymap: km, saveTo: saveTo, background: background, aspect: aspect)
    case "new":
        let name = a.required(0, "name")
        guard name.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else {
            fail("keymap names use lowercase letters, digits and dashes")
        }
        let url = paths.keymaps.appendingPathComponent("\(name).json")
        if FileManager.default.fileExists(atPath: url.path) { fail("\(url.path) already exists") }
        // JoystickControl only has the synthesized Codable initializer, so build it from JSON.
        let stick = try! JSONDecoder().decode(Control.self, from: Data("""
            {"type":"joystick","up":"W","down":"S","left":"A","right":"D","stick":"left","center":[0.15,0.72],"radius":0.065}
            """.utf8))
        var km = Keymap(name: name, package: a.positional.dropFirst().first, controls: [stick])
        km.description = "Created with kestrel keymap new. Add controls with kestrel keymap edit."
        run {
            try FileManager.default.createDirectory(at: paths.keymaps, withIntermediateDirectories: true)
            try km.encoded().write(to: url, options: .atomic)
        }
        print(url.path)
    default:
        fail("unknown keymap subcommand '\(sub)'")
    }

case "tap":
    let a = Args(rest, valued: [])
    let store = storeOrFail()
    run {
        let inst = try store.load(a.index())
        guard let x = Double(a.required(1, "x")), let y = Double(a.required(2, "y")), (0...1).contains(x), (0...1).contains(y) else {
            fail("x and y must be numbers in 0...1")
        }
        let sink = try DeviceSink(adb: adbFor(inst.index, store), width: inst.settings.width, height: inst.settings.height)
        let px = Int((x * Double(inst.settings.width - 1)).rounded()), py = Int((y * Double(inst.settings.height - 1)).rounded())
        try sink.send([.down(slot: 0, x: px, y: py)])
        usleep(50_000)
        try sink.send([.up(slot: 0)])
        sink.close()
        print("tapped \(px),\(py) via \(sink.readyLine)")
    }

case "play":
    let a = Args(rest, valued: ["keymap", "record"])
    let store = storeOrFail()
    run {
        let inst = try store.load(a.index())
        let km = try playKeymap(a, inst)
        try PlaySession.run(instance: inst, store: store, keymap: km, dryRun: a.flags.contains("dry-run"),
                            recordTo: a.options["record"].map { URL(fileURLWithPath: $0) })
    }

case "replay":
    let a = Args(rest, valued: ["keymap"])
    let store = storeOrFail()
    run {
        let inst = try store.load(a.index())
        let km = try playKeymap(a, inst)
        let file = a.required(1, "recording file")
        let recording = try InputRecording.parse(String(contentsOfFile: file, encoding: .utf8))
        let s = inst.settings
        let dry = a.flags.contains("dry-run")
        let sink: TouchSink = dry ? PrintSink()
            : try DeviceSink(adb: adbFor(inst.index, store), width: s.width, height: s.height)
        let driver = Driver(engine: KeymapEngine(keymap: km, screenWidth: s.width, screenHeight: s.height,
                                                 sensitivity: s.mouseSensitivity), sink: sink)
        driver.onError = { FileHandle.standardError.write(Data("kestrel: \($0)\n".utf8)) }
        print("Replaying \(recording.entries.count) events (\(Int(recording.duration)) ms) with '\(km.name)'…")
        driver.replay(recording)
        driver.stop()
        print("Done.")
    }

default:
    fail("unknown command '\(command)'. Run `kestrel --help`.")
}
