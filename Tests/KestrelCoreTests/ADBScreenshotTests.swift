import Foundation
import XCTest
@testable import KestrelCore

final class ADBScreenshotTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("adb-screenshot-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("platform-tools"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func adb(_ body: String) throws -> ADB {
        let executable = root.appendingPathComponent("platform-tools/adb")
        try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return ADB(sdk: AndroidSDK(root: root), serial: "emulator-5580")
    }

    func testHungScreenshotTimesOutRatherThanOccupyingWorker() throws {
        let client = try adb("exec /bin/sleep 2")
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try client.screenshotData(timeout: 0.05)) {
            XCTAssertEqual($0 as? PlayerCommandError, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 1)
    }

    func testPreservesBinaryPNGBytesAndUsesExpectedArguments() throws {
        let client = try adb("[ \"$1 $2 $3 $4 $5\" = '-s emulator-5580 exec-out screencap -p' ] || exit 9\nprintf '\\211PNG\\015\\012\\032\\012\\377\\000'")
        XCTAssertEqual(try client.screenshotData(), Data([137,80,78,71,13,10,26,10,255,0]))
        XCTAssertThrowsError(try client.screenshotData(maximumBytes: 8)) {
            XCTAssertEqual($0 as? PlayerCaptureError, .outputTooLarge)
        }
    }

    func testRejectsTruncatedPNGSignature() throws {
        let client = try adb("printf '\\211PNG'")
        XCTAssertThrowsError(try client.screenshotData())
    }
}
