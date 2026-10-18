import Foundation
import XCTest
@testable import KestrelCore

final class OwnedEmulatorProcessTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("owned-vm-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func child() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    func testStopsOnlyRetainedChildAndRemovesMatchingPIDFile() throws {
        let process = try child()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let file = directory.appendingPathComponent("emulator.pid")
        try String(process.processIdentifier).write(to: file, atomically: true, encoding: .utf8)
        let owned = OwnedEmulatorProcess(process: process, pidFile: file)
        var requests = 0
        try owned.stop(gracePeriod: 0.05) {
            requests += 1
            process.terminate()
        }
        XCTAssertFalse(process.isRunning)
        XCTAssertFalse(owned.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try owned.stop(gracePeriod: 0.05) { requests += 1 }
        XCTAssertEqual(requests, 1, "Stop is idempotent and never targets a reused PID")
    }

    func testReplacedPIDFileDoesNotRedirectShutdownOrGetRemoved() throws {
        let process = try child()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let file = directory.appendingPathComponent("emulator.pid")
        let otherPID = String(ProcessInfo.processInfo.processIdentifier)
        try otherPID.write(to: file, atomically: true, encoding: .utf8)
        let owned = OwnedEmulatorProcess(process: process, pidFile: file)
        try owned.stop(gracePeriod: 0.05) { throw KestrelError.runtime("ADB unavailable") }
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), otherPID)
    }

    func testSymlinkPIDFileIsNeverFollowedOrRemoved() throws {
        let process = try child()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let target = directory.appendingPathComponent("another-file")
        let text = String(process.processIdentifier)
        try text.write(to: target, atomically: true, encoding: .utf8)
        let alias = directory.appendingPathComponent("emulator.pid")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let owned = OwnedEmulatorProcess(process: process, pidFile: alias)
        try owned.stop(gracePeriod: 0.05) { process.terminate() }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path), target.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), text)
    }

    func testAtomicReplacementWithSamePIDAfterAcquisitionIsPreserved() throws {
        let process = try child()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let file = directory.appendingPathComponent("emulator.pid")
        let text = String(process.processIdentifier)
        try text.write(to: file, atomically: true, encoding: .utf8)
        let owned = OwnedEmulatorProcess(process: process, pidFile: file)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try owned.stop(gracePeriod: 0.05) { process.terminate() }
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), text)
    }

    func testReadinessWaitRetriesUntilReady() throws {
        let process = try child()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let owned = OwnedEmulatorProcess(process: process, pidFile: directory.appendingPathComponent("missing.pid"))
        var attempts = 0
        try owned.waitUntilReady(timeout: 1, pollInterval: 0.01) { _ in
            attempts += 1
            return attempts == 3
        }
        XCTAssertEqual(attempts, 3)
        XCTAssertTrue(process.isRunning)
    }

    func testReadinessCancellationPreventsProbeAndCallerCanCleanUp() throws {
        let process = try child()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let owned = OwnedEmulatorProcess(process: process, pidFile: directory.appendingPathComponent("missing.pid"))
        XCTAssertThrowsError(try owned.waitUntilReady(timeout: 1, isCancelled: { true }) { _ in
            XCTFail("Cancelled wait invoked readiness probe")
            return true
        }) { XCTAssertTrue($0 is CancellationError) }
        try owned.stop(gracePeriod: 0)
        XCTAssertFalse(process.isRunning)
    }

    func testReadinessTimeoutAndChildExitAreNotReportedReady() throws {
        let process = try child()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        let owned = OwnedEmulatorProcess(process: process, pidFile: directory.appendingPathComponent("missing.pid"))
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try owned.waitUntilReady(timeout: 0.05, pollInterval: 0.01) { budget in
            XCTAssertGreaterThan(budget, 0)
            XCTAssertLessThanOrEqual(budget, 0.05)
            return false
        })
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1)
        try owned.stop(gracePeriod: 0)
        XCTAssertThrowsError(try owned.waitUntilReady(timeout: 1) { _ in
            XCTFail("Exited child invoked readiness probe")
            return true
        })
    }

    func testInvalidGracePeriodDoesNotInvokeShutdown() throws {
        let process = try child()
        defer { process.terminate(); process.waitUntilExit() }
        let owned = OwnedEmulatorProcess(process: process, pidFile: directory.appendingPathComponent("missing.pid"))
        for grace in [-1.0, .nan, .infinity, 61] {
            XCTAssertThrowsError(try owned.stop(gracePeriod: grace) { XCTFail("Invalid timeout invoked shutdown") })
        }
        XCTAssertTrue(process.isRunning)
    }
}
