import Foundation

public enum GPUMode: String, Codable, CaseIterable, Sendable {
    /// Host GPU through gfxstream -> MoltenVK/ANGLE -> Metal (fastest path).
    case host
    /// Software Vulkan/GL (SwiftShader). Compatibility fallback.
    case swiftshader = "swiftshader_indirect"
}

public enum PerformancePreset: String, Codable, CaseIterable, Sendable {
    case low, medium, high, custom
}

/// Per-instance configuration. Field names cover the usual gaming-emulator knobs
/// (vmCpuCount, vmMemoryOfMB, fpsLimit, ...) but this is an independent format.
public struct InstanceSettings: Codable, Equatable, Sendable {
    public var name: String
    public var cpuCount: Int
    public var memoryMB: Int
    public var width: Int
    public var height: Int
    public var dpi: Int
    public var gpuMode: GPUMode
    public var vulkan: Bool
    public var disableAsyncSwap: Bool?
    public var fpsLimit: Int
    public var showFPS: Bool
    public var performance: PerformancePreset
    public var deviceBrand: String?
    public var deviceModel: String?
    /// Optional `DeviceIdentity` profile id; when set, the launcher presents
    /// that full phone identity to the guest (see `DeviceIdentity.swift`).
    public var deviceIdentityPreset: String?
    public var dataPartitionGB: Int
    public var systemImage: String
    public var keymap: String?
    public var mouseSensitivity: Double
    public var audio: Bool
    public var window: Bool

    public init(
        name: String,
        cpuCount: Int = 4,
        memoryMB: Int = 4096,
        width: Int = 1920,
        height: Int = 1080,
        dpi: Int = 280,
        gpuMode: GPUMode = .host,
        vulkan: Bool = true,
        disableAsyncSwap: Bool? = nil,
        fpsLimit: Int = 60,
        showFPS: Bool = false,
        performance: PerformancePreset = .medium,
        deviceBrand: String? = nil,
        deviceModel: String? = nil,
        deviceIdentityPreset: String? = nil,
        dataPartitionGB: Int = 16,
        systemImage: String = "system-images;android-36;google_apis_playstore;arm64-v8a",
        keymap: String? = nil,
        mouseSensitivity: Double = 1.0,
        audio: Bool = true,
        window: Bool = true
    ) {
        self.name = name
        self.cpuCount = cpuCount
        self.memoryMB = memoryMB
        self.width = width
        self.height = height
        self.dpi = dpi
        self.gpuMode = gpuMode
        self.vulkan = vulkan
        self.disableAsyncSwap = disableAsyncSwap
        self.fpsLimit = fpsLimit
        self.showFPS = showFPS
        self.performance = performance
        self.deviceBrand = deviceBrand
        self.deviceModel = deviceModel
        self.deviceIdentityPreset = deviceIdentityPreset
        self.dataPartitionGB = dataPartitionGB
        self.systemImage = systemImage
        self.keymap = keymap
        self.mouseSensitivity = mouseSensitivity
        self.audio = audio
        self.window = window
    }

    /// Validation errors, empty when the settings are usable.
    public func validate() -> [String] {
        var errors: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("name must not be empty") }
        if !(1...16).contains(cpuCount) { errors.append("cpuCount must be 1-16") }
        if !(1024...32768).contains(memoryMB) { errors.append("memoryMB must be 1024-32768") }
        if !(320...7680).contains(width) || !(320...7680).contains(height) { errors.append("resolution must be 320-7680 per side") }
        if !(120...640).contains(dpi) { errors.append("dpi must be 120-640") }
        if ![30, 60, 90, 120, 144, 165, 240].contains(fpsLimit) { errors.append("fpsLimit must be one of 30,60,90,120,144,165,240") }
        if !(2...512).contains(dataPartitionGB) { errors.append("dataPartitionGB must be 2-512") }
        if !(0.1...10).contains(mouseSensitivity) { errors.append("mouseSensitivity must be 0.1-10") }
        if let preset = deviceIdentityPreset, DeviceIdentity.profile(preset) == nil {
            errors.append("deviceIdentityPreset '\(preset)' is not a known identity (known: \(DeviceIdentity.all.map(\.id).joined(separator: ", ")))")
        }
        if systemImage.split(separator: ";").count != 4 { errors.append("systemImage must look like system-images;android-NN;tag;abi") }
        return errors
    }

    /// Applies a JSON object of partial updates (same keys as the Codable form).
    public func merging(json: Data) throws -> InstanceSettings {
        let encoder = JSONEncoder()
        var base = try JSONSerialization.jsonObject(with: encoder.encode(self)) as! [String: Any]
        guard let patch = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw KestrelError.invalid("settings patch must be a JSON object")
        }
        let known = Set(base.keys).union(["deviceBrand", "deviceModel", "deviceIdentityPreset", "keymap", "disableAsyncSwap"])
        for (k, v) in patch {
            guard known.contains(k) else { throw KestrelError.invalid("unknown setting '\(k)'") }
            base[k] = v
        }
        let merged = try JSONDecoder().decode(InstanceSettings.self, from: JSONSerialization.data(withJSONObject: base))
        let errors = merged.validate()
        if !errors.isEmpty { throw KestrelError.invalid(errors.joined(separator: "; ")) }
        return merged
    }
}

public enum KestrelError: Error, CustomStringConvertible, Equatable {
    case invalid(String)
    case notFound(String)
    case environment(String)
    case runtime(String)

    public var description: String {
        switch self {
        case .invalid(let m): return "invalid: \(m)"
        case .notFound(let m): return "not found: \(m)"
        case .environment(let m): return "environment: \(m)"
        case .runtime(let m): return m
        }
    }
}
