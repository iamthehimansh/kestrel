import Foundation

/// Installs and checks the Android SDK pieces Kestrel needs. The default system image is
/// Google's "Google Play" image, which ships the Play Store and Google Play services, so
/// apps install straight from the Play Store after signing in to a Google account in Android.
public enum SDKSetup {
    public struct Component: Sendable {
        public let package: String
        public let purpose: String
        public let required: Bool
    }

    public static let defaultImage = "system-images;android-36;google_apis_playstore;arm64-v8a"

    public static let components: [Component] = [
        .init(package: "emulator", purpose: "virtual machine (QEMU + Hypervisor.framework, Metal graphics)", required: true),
        .init(package: "platform-tools", purpose: "adb", required: true),
        .init(package: defaultImage, purpose: "Android 16 with Google Play Store and Play services", required: true),
        .init(package: "ndk;27.1.12297006", purpose: "only for building touchd from source", required: false),
    ]

    /// The SDK folder to use, whether or not anything is installed in it yet.
    public static func sdkRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let v = env["ANDROID_SDK_ROOT"] ?? env["ANDROID_HOME"] { return URL(fileURLWithPath: v) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk")
    }

    public static func isInstalled(_ package: String, root: URL) -> Bool {
        let fm = FileManager.default
        let sdk = AndroidSDK(root: root)
        switch package {
        case "emulator": return fm.isExecutableFile(atPath: sdk.emulator.path)
        case "platform-tools": return fm.isExecutableFile(atPath: sdk.adb.path)
        default:
            if package.hasPrefix("system-images;") { return sdk.hasSystemImage(package) }
            if package.hasPrefix("ndk;") { return sdk.ndkClang() != nil }
            return false
        }
    }

    public static func isPlayImage(_ id: String) -> Bool {
        id.split(separator: ";").count == 4 && id.split(separator: ";")[2].contains("playstore")
    }

    /// sdkmanager from the SDK's own cmdline-tools, Homebrew, or PATH.
    public static func sdkmanager(root: URL) -> URL? {
        let fm = FileManager.default
        var candidates = [root.appendingPathComponent("cmdline-tools/latest/bin/sdkmanager")]
        let ct = root.appendingPathComponent("cmdline-tools")
        for v in ((try? fm.contentsOfDirectory(atPath: ct.path)) ?? []).sorted(by: >) {
            candidates.append(ct.appendingPathComponent("\(v)/bin/sdkmanager"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/share/android-commandlinetools/cmdline-tools/latest/bin/sdkmanager"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/sdkmanager"))
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("sdkmanager"))
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// Installs every missing component. Accepts the Android SDK licences on the user's behalf,
    /// which is what running `kestrel setup` asks for.
    public static func install(root: URL, includeOptional: Bool, log: (String) -> Void) throws {
        let missing = components.filter { (includeOptional || $0.required) && !isInstalled($0.package, root: root) }
        if missing.isEmpty { log("Everything is already installed."); return }
        var manager = sdkmanager(root: root)
        if manager == nil {
            let brew = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
            guard FileManager.default.isExecutableFile(atPath: brew.path) else {
                throw KestrelError.environment("""
                The Android command-line tools are not installed and Homebrew was not found.
                Install Homebrew (https://brew.sh), then run: kestrel setup
                """)
            }
            log("Installing Java and the Android command-line tools with Homebrew…")
            let r = try runProcess(brew, ["install", "--cask", "temurin", "android-commandlinetools"])
            if r.status != 0 { throw KestrelError.runtime("brew install failed:\n\(r.stderr.isEmpty ? r.stdout : r.stderr)") }
            manager = sdkmanager(root: root)
        }
        guard let manager else { throw KestrelError.environment("sdkmanager still not found after installing the command-line tools") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let yes = Data(String(repeating: "y\n", count: 64).utf8)
        log("Accepting Android SDK licences…")
        _ = try runProcess(manager, ["--sdk_root=\(root.path)", "--licenses"], input: yes)
        let packages = missing.map(\.package)
        log("Downloading \(packages.joined(separator: ", ")) (several GB; this takes a while)…")
        let r = try runProcess(manager, ["--sdk_root=\(root.path)", "--install"] + packages, input: yes)
        if r.status != 0 { throw KestrelError.runtime("sdkmanager failed:\n\(r.stderr.isEmpty ? r.stdout : r.stderr)") }
        let still = missing.filter { !isInstalled($0.package, root: root) }.map(\.package)
        if !still.isEmpty { throw KestrelError.runtime("still missing after install: \(still.joined(separator: ", "))") }
        log("Installed \(packages.count) component(s).")
    }

    /// Floor for Google Play images. A 2 GB Android 16 Play instance showed a
    /// "System isn't responding" dialog right after boot in testing, so new Play
    /// instances get at least 3 GB.
    public static let playMinimumMemoryMB = 3072
}
