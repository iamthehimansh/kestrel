import Foundation
import XCTest
@testable import KestrelCore

final class PlayerCommandCaptureTests: XCTestCase {
    func testCapturesOutputAndRejectsNonzeroExit() throws {
        XCTAssertEqual(try PlayerCommandCapture.run(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "viewport evidence"]), "viewport evidence")
        XCTAssertThrowsError(try PlayerCommandCapture.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])) {
            XCTAssertEqual($0 as? PlayerCommandError, .failed(1))
        }
    }

    func testLimitRejectsRatherThanReturningTruncatedOutput() throws {
        XCTAssertThrowsError(try PlayerCommandCapture.run(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "12345"], maximumBytes: 4)) {
            XCTAssertEqual($0 as? PlayerCaptureError, .outputTooLarge)
        }
        XCTAssertEqual(try PlayerCommandCapture.run(executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "1234"], maximumBytes: 4), "1234")
    }

    func testSilentChildTimesOutAndIsReaped() {
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try PlayerCommandCapture.run(executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"], timeout: 0.05)) {
            XCTAssertEqual($0 as? PlayerCommandError, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
    }

    func testInvalidBoundsRejectedBeforeLaunch() {
        let missing = URL(fileURLWithPath: "/missing-command")
        for timeout in [-1.0, 0, .nan, .infinity, 31] {
            XCTAssertThrowsError(try PlayerCommandCapture.run(executable: missing, arguments: [], timeout: timeout)) {
                XCTAssertEqual($0 as? PlayerCommandError, .invalidTimeout)
            }
        }
        for maximum in [0, -1, 1_048_577] {
            XCTAssertThrowsError(try PlayerCommandCapture.run(executable: missing, arguments: [], maximumBytes: maximum)) {
                XCTAssertEqual($0 as? PlayerCaptureError, .invalidLimit)
            }
        }
    }
}
