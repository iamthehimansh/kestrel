import Foundation

/// Locates the open-source Android Emulator (QEMU + Hypervisor.framework, gfxstream,
/// ANGLE, MoltenVK) and platform-tools from an Android SDK install.
public struct AndroidSDK: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func locate() throws -> AndroidSDK {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let v = env["ANDROID_SDK_ROOT"] { candidates.append(v) }
        if let v = env["ANDROID_HOME"] { candidates.append(v) }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk").path)
        candidates.append("/opt/homebrew/share/android-commandlinetools")
        for c in candidates {
            let sdk = AndroidSDK(root: URL(fileURLWithPath: c))
            if FileManager.default.isExecutableFile(atPath: sdk.emulator.path) { return sdk }
        }
        throw KestrelError.environment("""
        Android SDK with the emulator not found. Install it with:
          brew install --cask android-commandlinetools
          sdkmanager "emulator" "platform-tools" "system-images;android-36;google_apis_playstore;arm64-v8a"
        or set ANDROID_SDK_ROOT.
        """)
    }

    public var emulator: URL { root.appendingPathComponent("emulator/emulator") }
    public var adb: URL { root.appendingPathComponent("platform-tools/adb") }

    public func systemImageDir(_ id: String) -> URL {
        id.split(separator: ";").reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    public func hasSystemImage(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: systemImageDir(id).appendingPathComponent("system.img").path)
    }

    public func installedSystemImages() -> [String] {
        let base = root.appendingPathComponent("system-images")
        let fm = FileManager.default
        var out: [String] = []
        for api in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] {
            for tag in (try? fm.contentsOfDirectory(atPath: base.appendingPathComponent(api).path)) ?? [] {
                for abi in (try? fm.contentsOfDirectory(atPath: base.appendingPathComponent("\(api)/\(tag)").path)) ?? [] {
                    let id = "system-images;\(api);\(tag);\(abi)"
                    if hasSystemImage(id) { out.append(id) }
                }
            }
        }
        return out.sorted()
    }

    public func ndkClang(api: Int = 29) -> URL? {
        let ndkBase = root.appendingPathComponent("ndk")
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: ndkBase.path) else { return nil }
        for v in versions.sorted(by: >) {
            for host in ["darwin-x86_64", "darwin-arm64"] {
                let clang = ndkBase.appendingPathComponent("\(v)/toolchains/llvm/prebuilt/\(host)/bin/aarch64-linux-android\(api)-clang")
                if FileManager.default.isExecutableFile(atPath: clang.path) { return clang }
            }
        }
        return nil
    }
}
