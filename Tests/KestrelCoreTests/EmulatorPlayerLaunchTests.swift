import Foundation
import XCTest
@testable import KestrelCore

final class EmulatorPlayerLaunchTests: XCTestCase {
    private var directory: URL!
    private var policy: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("player-launch-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        policy = directory.appendingPathComponent("access.json")
        try EmulatorTokenSigner.accessPolicy().write(to: policy)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testNativeArgumentsAlwaysRequireJWTAndHideExternalWindow() throws {
        let player = try EmulatorPlayerLaunch(port: 8556, policyFile: policy)
        let instance = Instance(index: 0, settings: InstanceSettings(name: "Player"))
        let normal = Launcher.arguments(for: instance, avdName: "kestrel-0")
        XCTAssertFalse(normal.contains("-grpc"))
        XCTAssertFalse(normal.contains("-no-window"))
        let arguments = Launcher.arguments(for: instance, avdName: "kestrel-0", player: player)
        XCTAssertTrue(arguments.contains("-grpc-use-jwt"))
        XCTAssertEqual(arguments.filter { $0 == "-no-window" }.count, 1)
        let grpc = try XCTUnwrap(arguments.firstIndex(of: "-grpc"))
        XCTAssertEqual(arguments[grpc + 1], "8556")
        let allowlist = try XCTUnwrap(arguments.firstIndex(of: "-grpc-allowlist"))
        XCTAssertEqual(arguments[allowlist + 1], policy.path)
        XCTAssertFalse(arguments.contains("-grpc-use-token"))
        XCTAssertTrue(instance.settings.window, "Native launch must not overwrite the saved profile")
    }

    func testRejectsInvalidPortAndNonFilePolicy() {
        for port in [-1, 0, 80, 65536] {
            XCTAssertThrowsError(try EmulatorPlayerLaunch(port: port, policyFile: policy))
        }
        XCTAssertThrowsError(try EmulatorPlayerLaunch(port: 8556,
            policyFile: URL(string: "https://example.com/access.json")!))
    }

    func testPolicyMustBeExactGeneratedProtectedPolicy() throws {
        let player = try EmulatorPlayerLaunch(port: 8556, policyFile: policy)
        try player.validate(for: Ports.forInstance(0))
        try Data(#"{"unprotected":[".*"],"allowlist":[]}"#.utf8).write(to: policy)
        XCTAssertThrowsError(try player.validate(for: Ports.forInstance(0)))
        try FileManager.default.removeItem(at: policy)
        XCTAssertThrowsError(try player.validate(for: Ports.forInstance(0)))
    }

    func testRejectsSymlinkAndConsolePortCollision() throws {
        let alias = directory.appendingPathComponent("alias.json")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: policy)
        let linked = try EmulatorPlayerLaunch(port: 8556, policyFile: alias)
        XCTAssertThrowsError(try linked.validate(for: Ports.forInstance(0)))
        for port in [5580, 5581] {
            let conflict = try EmulatorPlayerLaunch(port: port, policyFile: policy)
            XCTAssertThrowsError(try conflict.validate(for: Ports.forInstance(0)))
        }
    }

    func testNativeStartRefusesToReuseAnExistingProcess() throws {
        let sdk = AndroidSDK(root: directory.appendingPathComponent("sdk"))
        let store = InstanceStore(paths: KestrelPaths(root: directory.appendingPathComponent("home")), sdk: sdk)
        let instance = try store.create(name: "Already running")
        let launcher = Launcher(store: store)
        try String(ProcessInfo.processInfo.processIdentifier).write(to: launcher.pidFile(instance.index),
            atomically: true, encoding: .utf8)
        let player = try EmulatorPlayerLaunch(port: 8556, policyFile: policy)
        XCTAssertThrowsError(try launcher.start(instance.index, player: player))
        XCTAssertThrowsError(try launcher.startOwned(instance.index, player: player))
        XCTAssertEqual(try launcher.start(instance.index), ProcessInfo.processInfo.processIdentifier,
                       "Legacy launch behavior unchanged by this optional path")
    }
}
