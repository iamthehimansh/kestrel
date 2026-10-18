import Foundation

/// Builds the emulator command line for an instance and manages its process.
public struct Launcher {
    public let store: InstanceStore
    public init(store: InstanceStore) { self.store = store }

    /// `snapshot` boots from that saved state and leaves it unchanged on exit (the normal
    /// quick-boot state is still saved separately when stopping).
    public static func arguments(for instance: Instance, avdName: String, coldBoot: Bool = false, snapshot: String? = nil) -> [String] {
        let s = instance.settings
        let p = instance.ports
        var args = [
            "-avd", avdName,
            "-ports", "\(p.console),\(p.adb)",
            "-cores", "\(s.cpuCount)",
            "-memory", "\(s.memoryMB)",
            "-gpu", s.gpuMode.rawValue,
            "-accel", "on",
            "-no-boot-anim",
            "-netdelay", "none",
            "-netspeed", "full",
        ]
        if !s.window { args.append("-no-window") }
        if !s.audio { args.append("-no-audio") }
        if let snapshot {
            args += ["-snapshot", snapshot, "-no-snapshot-save", "-force-snapshot-load"]
        } else if coldBoot {
            args.append("-no-snapshot-load")
        }
        args += ["-feature", s.vulkan ? "Vulkan" : "-Vulkan"]
        if s.vulkan { args += ["-feature", "GLDirectMem"] }
        if let presetID = s.deviceIdentityPreset, let identity = DeviceIdentity.profile(presetID) {
            // Full coherent phone identity: every guest-visible identity value
            // moves together (research/stealth/FINDINGS.md vectors 1-13).
            for (name, value) in identity.properties { args += ["-prop", "\(name)=\(value)"] }
        } else {
            if let brand = s.deviceBrand { args += ["-prop", "ro.product.brand=\(brand)"] }
            if let model = s.deviceModel { args += ["-prop", "ro.product.model=\(model)"] }
        }
        return args
    }

    public func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_AVD_HOME"] = store.paths.avdHome.path
        env["ANDROID_SDK_ROOT"] = store.sdk.root.path
        // Run Vulkan through MoltenVK (Metal).
        env["ANDROID_EMU_VK_ICD"] = "moltenvk"
        return env
    }

    public func logFile(_ index: Int) -> URL { store.paths.instanceDir(index).appendingPathComponent("emulator.log") }
    func pidFile(_ index: Int) -> URL { store.paths.instanceDir(index).appendingPathComponent("emulator.pid") }

    public func runningPID(_ index: Int) -> Int32? {
        guard let s = try? String(contentsOf: pidFile(index)), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return kill(pid, 0) == 0 ? pid : nil
    }

    @discardableResult
    public func start(_ index: Int, coldBoot: Bool = false, snapshot: String? = nil) throws -> Int32 {
        let inst = try store.load(index)
        if let pid = runningPID(index) { return pid }
        guard store.sdk.hasSystemImage(inst.settings.systemImage) else {
            throw KestrelError.environment("system image \(inst.settings.systemImage) is not installed; run: kestrel setup")
        }
        if let snapshot, !Snapshots(store: store).list(index).contains(where: { $0.name == snapshot }) {
            throw KestrelError.notFound("snapshot '\(snapshot)'")
        }
        try store.save(inst)
        let proc = Process()
        proc.executableURL = store.sdk.emulator
        proc.arguments = Self.arguments(for: inst, avdName: store.paths.avdName(index), coldBoot: coldBoot, snapshot: snapshot)
        proc.environment = environment()
        FileManager.default.createFile(atPath: logFile(index).path, contents: nil)
        let log = try FileHandle(forWritingTo: logFile(index))
        proc.standardOutput = log
        proc.standardError = log
        proc.standardInput = FileHandle.nullDevice
        try proc.run()
        try "\(proc.processIdentifier)".write(to: pidFile(index), atomically: true, encoding: .utf8)
        return proc.processIdentifier
    }

    public func stop(_ index: Int) throws {
        let inst = try store.load(index)
        let adb = ADB(sdk: store.sdk, serial: inst.ports.serial)
        _ = try? adb.run(["emu", "kill"])
        if let pid = runningPID(index) {
            // Graceful console kill first, then SIGTERM, then SIGKILL; only report stopped
            // once the process is really gone.
            func waitExit(_ tenths: Int) -> Bool {
                for _ in 0..<tenths where kill(pid, 0) == 0 { usleep(100_000) }
                return kill(pid, 0) != 0
            }
            if !waitExit(50) {
                kill(pid, SIGTERM)
                if !waitExit(50) {
                    kill(pid, SIGKILL)
                    if !waitExit(20) { throw KestrelError.runtime("emulator pid \(pid) did not exit") }
                }
            }
        }
        try? FileManager.default.removeItem(at: pidFile(index))
    }

    /// Waits until Android reports sys.boot_completed=1.
    public func waitForBoot(_ index: Int, timeout: TimeInterval = 300) throws {
        let inst = try store.load(index)
        let adb = ADB(sdk: store.sdk, serial: inst.ports.serial)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if runningPID(index) == nil { throw KestrelError.runtime("emulator exited; see \(logFile(index).path)") }
            if let out = try? adb.shell("getprop sys.boot_completed"), out.trimmingCharacters(in: .whitespacesAndNewlines) == "1" { return }
            Thread.sleep(forTimeInterval: 2)
        }
        throw KestrelError.runtime("boot timed out after \(Int(timeout))s")
    }
}
