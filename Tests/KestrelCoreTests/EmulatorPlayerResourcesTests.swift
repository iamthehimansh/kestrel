import Foundation
import XCTest
@testable import KestrelCore

final class EmulatorPlayerResourcesTests: XCTestCase {
    private var directory: URL!
    private var child: Process!
    private var owned: OwnedEmulatorProcess!
    private var registration: EmulatorPublicKeyRegistration!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("player-resources-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        owned = OwnedEmulatorProcess(process: child, pidFile: directory.appendingPathComponent("missing.pid"))
        registration = try EmulatorPublicKeyRegistration(directory: directory, signer: EmulatorTokenSigner())
    }

    override func tearDownWithError() throws {
        if child?.isRunning == true { child.terminate(); child.waitUntilExit() }
        registration = nil
        owned = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testCloseRevokesBeforeStoppingAndIsIdempotent() throws {
        let resources = EmulatorPlayerResources(process: owned, registration: registration)
        let file = directory.appendingPathComponent(registration.fileName)
        var requests = 0
        try resources.close(gracePeriod: 0.05) {
            requests += 1
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            self.child.terminate()
        }
        XCTAssertFalse(child.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try resources.close { requests += 1 }
        XCTAssertEqual(requests, 1)
    }

    func testRevocationFailureStillStopsChildAndCanBeRetried() throws {
        let resources = EmulatorPlayerResources(process: owned, registration: registration)
        let file = directory.appendingPathComponent(registration.fileName)
        let moved = directory.appendingPathComponent("original.jwk")
        try FileManager.default.moveItem(at: file, to: moved)
        try Data("replacement".utf8).write(to: file)
        XCTAssertThrowsError(try resources.close(gracePeriod: 0)) {
            XCTAssertEqual($0 as? EmulatorPlayerCleanupError,
                           .incomplete(keyRevocationFailed: true, processShutdownFailed: false))
        }
        XCTAssertFalse(child.isRunning)
        XCTAssertEqual(try Data(contentsOf: file), Data("replacement".utf8))
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: moved, to: file)
        try resources.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testProcessFailureDoesNotPreventRevocationOrRetry() throws {
        let resources = EmulatorPlayerResources(process: owned, registration: registration)
        let file = directory.appendingPathComponent(registration.fileName)
        XCTAssertThrowsError(try resources.close(gracePeriod: -1)) {
            XCTAssertEqual($0 as? EmulatorPlayerCleanupError,
                           .incomplete(keyRevocationFailed: false, processShutdownFailed: true))
        }
        XCTAssertTrue(child.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try resources.close(gracePeriod: 0)
        XCTAssertFalse(child.isRunning)
    }
}
