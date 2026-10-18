import Foundation

/// Where everything lives. Instances are kept in Kestrel's own AVD home so the
/// user's ~/.android/avd is never touched.
public struct KestrelPaths: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        if let root { self.root = root; return }
        if let env = ProcessInfo.processInfo.environment["KESTREL_HOME"] {
            self.root = URL(fileURLWithPath: env)
        } else {
            self.root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Kestrel")
        }
    }

    public var avdHome: URL { root.appendingPathComponent("avd") }
    public var instances: URL { root.appendingPathComponent("instances") }
    public var keymaps: URL { root.appendingPathComponent("keymaps") }
    public func instanceDir(_ index: Int) -> URL { instances.appendingPathComponent("\(index)") }
    public func avdName(_ index: Int) -> String { "kestrel-\(index)" }
    public func avdDir(_ index: Int) -> URL { avdHome.appendingPathComponent("kestrel-\(index).avd") }
    public func avdIni(_ index: Int) -> URL { avdHome.appendingPathComponent("kestrel-\(index).ini") }
}

public struct Ports: Equatable, Sendable {
    public let console: Int
    public let adb: Int
    /// The emulator requires an even console port in 5554...5682 with adb = console + 1.
    public static func forInstance(_ index: Int) -> Ports {
        let console = 5580 + index * 2
        return Ports(console: console, adb: console + 1)
    }
    public var serial: String { "emulator-\(console)" }
}

public struct Instance: Sendable {
    public let index: Int
    public var settings: InstanceSettings
    public var ports: Ports { .forInstance(index) }
}

public final class InstanceStore {
    public let paths: KestrelPaths
    public let sdk: AndroidSDK
    private let fm = FileManager.default

    public init(paths: KestrelPaths = KestrelPaths(), sdk: AndroidSDK) {
        self.paths = paths
        self.sdk = sdk
    }

    public func list() throws -> [Instance] {
        guard fm.fileExists(atPath: paths.instances.path) else { return [] }
        return try fm.contentsOfDirectory(atPath: paths.instances.path)
            .compactMap(Int.init)
            .sorted()
            .compactMap { try? load($0) }
    }

    public func load(_ index: Int) throws -> Instance {
        let file = paths.instanceDir(index).appendingPathComponent("settings.json")
        guard let data = fm.contents(atPath: file.path) else { throw KestrelError.notFound("instance \(index)") }
        return Instance(index: index, settings: try JSONDecoder().decode(InstanceSettings.self, from: data))
    }

    public func save(_ instance: Instance) throws {
        let errors = instance.settings.validate()
        if !errors.isEmpty { throw KestrelError.invalid(errors.joined(separator: "; ")) }
        let dir = paths.instanceDir(instance.index)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(instance.settings).write(to: dir.appendingPathComponent("settings.json"), options: .atomic)
        try writeAVD(instance)
    }

    public func nextIndex() throws -> Int {
        let used = Set(try list().map(\.index))
        var i = 0
        while used.contains(i) { i += 1 }
        guard i < 52 else { throw KestrelError.invalid("at most 52 instances (emulator port range)") }
        return i
    }

    @discardableResult
    public func create(name: String?, preset: PerformancePreset = .medium, resolution: String? = nil) throws -> Instance {
        let index = try nextIndex()
        var settings = InstanceSettings(name: name ?? "Instance \(index)")
        let cm = Presets.cpuMemory(preset, hostCores: Host.cores, hostMemoryMB: Host.memoryMB)
        settings.cpuCount = cm.cpu
        settings.memoryMB = cm.memoryMB
        if SDKSetup.isPlayImage(settings.systemImage) {
            settings.memoryMB = max(settings.memoryMB, SDKSetup.playMinimumMemoryMB)
        }
        settings.performance = preset
        if let resolution {
            guard let r = Presets.resolution(resolution) else { throw KestrelError.invalid("unknown resolution preset '\(resolution)'") }
            settings.width = r.width; settings.height = r.height; settings.dpi = r.dpi
        }
        let inst = Instance(index: index, settings: settings)
        try save(inst)
        return inst
    }

    public func clone(_ index: Int) throws -> Instance {
        var src = try load(index)
        src.settings.name += " (copy)"
        let inst = Instance(index: try nextIndex(), settings: src.settings)
        try save(inst)
        return inst
    }

    public func delete(_ index: Int) throws {
        _ = try load(index)
        try? fm.removeItem(at: paths.avdDir(index))
        try? fm.removeItem(at: paths.avdIni(index))
        try fm.removeItem(at: paths.instanceDir(index))
    }

    /// Generates the AVD (config.ini + pointer .ini) from settings. Rewritten on every save so
    /// settings.json stays the single source of truth.
    func writeAVD(_ instance: Instance) throws {
        let dir = paths.avdDir(instance.index)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let pointer = """
        avd.ini.encoding=UTF-8
        path=\(dir.path)
        target=\(instance.settings.systemImage.split(separator: ";")[1])

        """
        try pointer.write(to: paths.avdIni(instance.index), atomically: true, encoding: .utf8)
        let capacity = try DiskCapacity.setting(requestedGB: instance.settings.dataPartitionGB, directory: dir)
        try AVDConfig.render(instance.settings, avdName: paths.avdName(instance.index), dataPartitionSize: capacity)
            .write(to: dir.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
    }
}

public enum AVDConfig {
    public static func render(_ s: InstanceSettings, avdName: String, dataPartitionSize: String? = nil) -> String {
        let parts = s.systemImage.split(separator: ";").map(String.init)
        let sysdir = parts.joined(separator: "/") + "/"
        let tag = parts[2]
        var lines: [(String, String)] = [
            ("AvdId", avdName),
            ("avd.ini.displayname", s.name),
            ("avd.ini.encoding", "UTF-8"),
            ("abi.type", parts[3]),
            ("hw.cpu.arch", parts[3].hasPrefix("arm64") ? "arm64" : "x86_64"),
            ("hw.cpu.ncore", "\(s.cpuCount)"),
            ("hw.ramSize", "\(s.memoryMB)"),
            ("vm.heapSize", "512"),
            ("hw.lcd.width", "\(s.width)"),
            ("hw.lcd.height", "\(s.height)"),
            ("hw.lcd.density", "\(s.dpi)"),
            ("hw.lcd.vsync", "\(s.fpsLimit)"),
            ("hw.initialOrientation", s.width >= s.height ? "landscape" : "portrait"),
            ("hw.gpu.enabled", "yes"),
            ("hw.gpu.mode", s.gpuMode.rawValue),
            ("hw.keyboard", "yes"),
            ("hw.mainKeys", "no"),
            ("hw.dPad", "no"),
            ("hw.gamepad", "yes"),
            ("hw.audioInput", s.audio ? "yes" : "no"),
            ("hw.audioOutput", s.audio ? "yes" : "no"),
            ("hw.accelerometer", "yes"),
            ("hw.gyroscope", "yes"),
            ("hw.sensors.orientation", "yes"),
            ("hw.gps", "yes"),
            ("hw.battery", "yes"),
            ("hw.camera.back", "emulated"),
            ("hw.camera.front", "emulated"),
            ("disk.dataPartition.size", dataPartitionSize ?? "\(s.dataPartitionGB)G"),
            ("fastboot.forceColdBoot", "no"),
            ("fastboot.forceFastBoot", "yes"),
            ("image.sysdir.1", sysdir),
            ("tag.id", tag),
            ("PlayStore.enabled", tag.contains("playstore") ? "true" : "false"),
            ("showDeviceFrame", "no"),
            ("skin.dynamic", "yes"),
            ("runtime.network.latency", "none"),
            ("runtime.network.speed", "full"),
        ]
        // Spoofed GPU strings when an identity profile is active: without
        // these the GL/GLES translator reports "Android Emulator OpenGL ES
        // Translator (<host chip>)" (FINDINGS.md vectors 14-16).
        if let preset = s.deviceIdentityPreset, let identity = DeviceIdentity.profile(preset) {
            lines += [
                ("hw.glrenderer", identity.glRenderer),
                ("hw.glvendor", identity.glVendor),
            ]
        }
        lines.sort { $0.0 < $1.0 }
        return lines.map { "\($0.0)=\($0.1)" }.joined(separator: "\n") + "\n"
    }
}
