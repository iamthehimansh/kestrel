import XCTest
@testable import KestrelCore

final class CoreTests: XCTestCase {
    var tmp: URL!
    var store: InstanceStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-test-\(UUID().uuidString)")
        let sdkRoot = tmp.appendingPathComponent("sdk")
        let img = sdkRoot.appendingPathComponent("system-images/android-36/google_apis_playstore/arm64-v8a")
        try FileManager.default.createDirectory(at: img, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: img.appendingPathComponent("system.img").path, contents: Data())
        store = InstanceStore(paths: KestrelPaths(root: tmp.appendingPathComponent("home")), sdk: AndroidSDK(root: sdkRoot))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testAsyncSwapCompatibilityIsOptInAndOldProfilesStillDecode() throws {
        let settings = InstanceSettings(name: "Legacy")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        object.removeValue(forKey: "disableAsyncSwap")
        let legacy = try JSONDecoder().decode(InstanceSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.disableAsyncSwap)
        XCTAssertEqual(try legacy.merging(json: Data(#"{"disableAsyncSwap":true}"#.utf8)).disableAsyncSwap, true)
        XCTAssertThrowsError(try legacy.merging(json: Data(#"{"disableAsyncSwap":"yes"}"#.utf8)))
        var instance = try store.create(name: "Compatibility")
        let baseline = Launcher.arguments(for: instance, avdName: "test")
        XCTAssertFalse(baseline.contains("-GLAsyncSwap"))
        instance.settings.disableAsyncSwap = true
        XCTAssertEqual(Launcher.arguments(for: instance, avdName: "test"), baseline + ["-feature", "-GLAsyncSwap"])
        try store.save(instance)
        XCTAssertEqual(try store.load(instance.index).settings.disableAsyncSwap, true)
        instance.settings.disableAsyncSwap = false
        XCTAssertEqual(Launcher.arguments(for: instance, avdName: "test"), baseline)
    }

    func testCreateListCloneDelete() throws {
        let a = try store.create(name: "Main", preset: .low, resolution: "tablet-1280x720")
        XCTAssertEqual(a.index, 0)
        XCTAssertEqual(a.settings.width, 1280)
        XCTAssertEqual(a.settings.cpuCount, 2)
        let b = try store.clone(0)
        XCTAssertEqual(b.index, 1)
        XCTAssertEqual(b.settings.name, "Main (copy)")
        XCTAssertEqual(try store.list().map(\.index), [0, 1])
        try store.delete(0)
        XCTAssertEqual(try store.list().map(\.index), [1])
        XCTAssertEqual(try store.nextIndex(), 0, "freed index is reused")
        XCTAssertThrowsError(try store.load(0))
    }

    func testAVDConfigGenerated() throws {
        let inst = try store.create(name: "G", preset: .medium, resolution: "phone-1080x2400")
        let cfg = try String(contentsOf: store.paths.avdDir(inst.index).appendingPathComponent("config.ini"))
        XCTAssertTrue(cfg.contains("hw.lcd.width=1080\n"))
        XCTAssertTrue(cfg.contains("hw.lcd.height=2400\n"))
        XCTAssertTrue(cfg.contains("hw.initialOrientation=portrait\n"))
        XCTAssertTrue(cfg.contains("image.sysdir.1=system-images/android-36/google_apis_playstore/arm64-v8a/\n"))
        XCTAssertTrue(cfg.contains("PlayStore.enabled=true\n"))
        XCTAssertTrue(cfg.contains("hw.gpu.mode=host\n"))
        let pointer = try String(contentsOf: store.paths.avdIni(inst.index))
        XCTAssertTrue(pointer.contains("path=\(store.paths.avdDir(inst.index).path)"))
    }

    func testConfigPatch() throws {
        var inst = try store.create(name: "P")
        inst.settings = try inst.settings.merging(json: Data(#"{"cpuCount":6,"fpsLimit":120,"gpuMode":"swiftshader_indirect"}"#.utf8))
        try store.save(inst)
        let back = try store.load(inst.index)
        XCTAssertEqual(back.settings.cpuCount, 6)
        XCTAssertEqual(back.settings.fpsLimit, 120)
        XCTAssertEqual(back.settings.gpuMode, .swiftshader)
        XCTAssertThrowsError(try back.settings.merging(json: Data(#"{"cpuCount":99}"#.utf8)))
        XCTAssertThrowsError(try back.settings.merging(json: Data(#"{"login":true}"#.utf8)), "unknown keys rejected")
        XCTAssertThrowsError(try back.settings.merging(json: Data(#"{"fpsLimit":75}"#.utf8)))
    }

    func testLaunchArguments() throws {
        var inst = try store.create(name: "L")
        inst.settings.window = false
        inst.settings.vulkan = true
        inst.settings.deviceModel = "SM-S928B"
        let args = Launcher.arguments(for: inst, avdName: "kestrel-0")
        XCTAssertEqual(Array(args.prefix(2)), ["-avd", "kestrel-0"])
        XCTAssertTrue(args.joined(separator: " ").contains("-ports 5580,5581"))
        XCTAssertTrue(args.contains("-no-window"))
        XCTAssertTrue(args.joined(separator: " ").contains("-feature Vulkan"))
        XCTAssertTrue(args.joined(separator: " ").contains("-prop ro.product.model=SM-S928B"))
        XCTAssertFalse(args.joined(separator: " ").lowercased().contains("login"))
    }

    func testPlayImageGetsMemoryFloor() throws {
        XCTAssertTrue(SDKSetup.isPlayImage("system-images;android-36;google_apis_playstore;arm64-v8a"))
        XCTAssertFalse(SDKSetup.isPlayImage("system-images;android-36;google_apis;arm64-v8a"))
        let inst = try store.create(name: "Play", preset: .low)
        XCTAssertGreaterThanOrEqual(inst.settings.memoryMB, SDKSetup.playMinimumMemoryMB)
        XCTAssertEqual(inst.settings.systemImage, SDKSetup.defaultImage)
    }

    func testSetupDetectsInstalledPieces() {
        let root = store.sdk.root
        XCTAssertTrue(SDKSetup.isInstalled(SDKSetup.defaultImage, root: root), "fixture has the Play image")
        XCTAssertFalse(SDKSetup.isInstalled("emulator", root: root), "fixture has no emulator binary")
        XCTAssertFalse(SDKSetup.isInstalled("platform-tools", root: root))
    }

    func testPortsUniquePerInstance() {
        let ports = (0..<52).map { Ports.forInstance($0) }
        XCTAssertEqual(Set(ports.map(\.console)).count, 52)
        XCTAssertTrue(ports.allSatisfy { $0.console % 2 == 0 && $0.adb == $0.console + 1 && $0.console <= 5682 })
        XCTAssertEqual(ports[0].serial, "emulator-5580")
    }

    func testPresetsLeaveHeadroom() {
        let (cpu, mem) = Presets.cpuMemory(.high, hostCores: 8, hostMemoryMB: 8192)
        XCTAssertLessThanOrEqual(cpu, 6)
        XCTAssertLessThanOrEqual(mem, 4096)
        let big = Presets.cpuMemory(.high, hostCores: 14, hostMemoryMB: 65536)
        XCTAssertEqual(big.cpu, 6)
        XCTAssertEqual(big.memoryMB, 12288)
    }

    func testMissingSystemImageIsReported() throws {
        var inst = try store.create(name: "X")
        inst.settings.systemImage = "system-images;android-30;default;arm64-v8a"
        try store.save(inst)
        XCTAssertThrowsError(try Launcher(store: store).start(inst.index)) { e in
            XCTAssertTrue("\(e)".contains("not installed"), "\(e)")
        }
    }
}
