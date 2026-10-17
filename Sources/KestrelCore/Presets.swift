import Foundation

public struct ResolutionPreset: Equatable, Sendable {
    public let id: String
    public let width: Int
    public let height: Int
    public let dpi: Int
}

public enum Presets {
    /// Landscape tablet-style and portrait phone-style presets (independent values).
    public static let resolutions: [ResolutionPreset] = [
        .init(id: "tablet-960x540", width: 960, height: 540, dpi: 160),
        .init(id: "tablet-1280x720", width: 1280, height: 720, dpi: 240),
        .init(id: "tablet-1600x900", width: 1600, height: 900, dpi: 240),
        .init(id: "tablet-1920x1080", width: 1920, height: 1080, dpi: 280),
        .init(id: "tablet-2560x1440", width: 2560, height: 1440, dpi: 400),
        .init(id: "tablet-3840x2160", width: 3840, height: 2160, dpi: 560),
        .init(id: "phone-720x1280", width: 720, height: 1280, dpi: 320),
        .init(id: "phone-1080x1920", width: 1080, height: 1920, dpi: 420),
        .init(id: "phone-1080x2400", width: 1080, height: 2400, dpi: 420),
        .init(id: "phone-1440x3200", width: 1440, height: 3200, dpi: 560),
    ]

    public static func resolution(_ id: String) -> ResolutionPreset? {
        resolutions.first { $0.id == id }
    }

    /// Picks vCPU / RAM for a performance level from the host's resources,
    /// always leaving at least 2 cores and 4 GB for macOS.
    public static func cpuMemory(_ level: PerformancePreset, hostCores: Int, hostMemoryMB: Int) -> (cpu: Int, memoryMB: Int) {
        let maxCPU = max(1, hostCores - 2)
        let maxMem = max(1024, hostMemoryMB - 4096)
        let (cpu, mem): (Int, Int)
        switch level {
        case .low: (cpu, mem) = (2, 2048)
        case .medium: (cpu, mem) = (4, hostMemoryMB >= 16384 ? 4096 : 3072)
        case .high:
            (cpu, mem) = (hostCores >= 10 ? 6 : 4,
                          hostMemoryMB >= 32768 ? 12288 : hostMemoryMB >= 16384 ? 6144 : 4096)
        case .custom: (cpu, mem) = (4, 4096)
        }
        return (min(cpu, maxCPU), min(mem, maxMem))
    }

    /// Device identity presets for apps that check the model (e.g. high-FPS whitelists).
    public static let devices: [String: (brand: String, model: String, manufacturer: String)] = [
        "pixel9pro": ("google", "Pixel 9 Pro", "Google"),
        "galaxys24ultra": ("samsung", "SM-S928B", "samsung"),
        "rog8": ("asus", "ASUS_AI2401", "asus"),
        "oneplus12": ("OnePlus", "CPH2581", "OnePlus"),
        "xiaomi14": ("Xiaomi", "23127PN0CG", "Xiaomi"),
    ]
}

public enum Host {
    public static var cores: Int { ProcessInfo.processInfo.activeProcessorCount }
    public static var memoryMB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) }
}
