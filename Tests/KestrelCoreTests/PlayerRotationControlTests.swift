import XCTest
@testable import KestrelCore

final class PlayerRotationControlTests: XCTestCase {
    private func viewport(_ rotation: Int) -> String {
        let w = rotation % 2 == 0 ? 1280 : 720
        let h = rotation % 2 == 0 ? 720 : 1280
        return "Viewport INTERNAL: displayId=0, orientation=\(rotation), logicalFrame=[0, 0, \(w), \(h)], isActive=[1]"
    }

    func testInspectionFailureIdentifiesCommandWithoutExposingDeviceIdentifier() {
        XCTAssertThrowsError(try PlayerRotationControl.inspect(
            adb: URL(fileURLWithPath: "/usr/bin/false"), serial: "private-device-identifier")) { error in
            let message = String(describing: error)
            XCTAssertTrue(message.contains("dumpsys input"), message)
            XCTAssertTrue(message.contains("failed(1)"), message)
            XCTAssertFalse(message.contains("private-device-identifier"))
        }
    }

    func testModeParsingAndFixedArguments() throws {
        XCTAssertEqual(try PlayerRotationMode.parse("free\n"), .free)
        XCTAssertEqual(try PlayerRotationMode.parse("lock 3"), .locked(.threeQuarter))
        XCTAssertEqual(PlayerRotationMode.locked(.quarter).arguments, ["wm", "user-rotation", "lock", "1"])
        for value in ["", "lock", "lock 4", "lock -1", "free 0", "lock 1 extra"] {
            XCTAssertThrowsError(try PlayerRotationMode.parse(value))
        }
    }

    func testWaitsForObservedRotationInsteadOfAcceptingCommandSuccess() throws {
        var requested = false
        var probes = 0
        let result = try PlayerRotationControl.rotate(command: { args in
            if args == ["wm", "user-rotation"] { return "free" }
            if args == ["wm", "user-rotation", "lock", "1"] { requested = true; return "" }
            XCTAssertEqual(args, ["dumpsys", "input"])
            if requested { probes += 1 }
            return self.viewport(probes >= 3 ? 1 : 0)
        }, wait: {})
        XCTAssertEqual(result.rotation, .quarter)
        XCTAssertEqual(probes, 3)
    }

    func testRefusedRotationRestoresPreviousMode() {
        var restored = false
        XCTAssertThrowsError(try PlayerRotationControl.rotate(command: { args in
            if args == ["wm", "user-rotation"] { return "free" }
            if args == ["wm", "user-rotation", "free"] { restored = true; return "" }
            if args == ["dumpsys", "input"] { return self.viewport(0) }
            XCTAssertEqual(args, ["wm", "user-rotation", "lock", "1"])
            return ""
        }, wait: {})) { XCTAssertEqual($0 as? PlayerRotationControlError, .refused) }
        XCTAssertTrue(restored)
    }

    func testRestoredModeWithoutRestoredViewportIsFailure() {
        var requested = false
        XCTAssertThrowsError(try PlayerRotationControl.rotate(command: { args in
            if args == ["wm", "user-rotation"] { return "free" }
            if args == ["wm", "user-rotation", "lock", "1"] {
                requested = true
                throw PlayerCommandError.failed(1)
            }
            if args == ["dumpsys", "input"] { return self.viewport(requested ? 2 : 0) }
            return ""
        }, wait: {})) { XCTAssertEqual($0 as? PlayerRotationControlError, .restorationFailed) }
    }

    func testCancellationBeforeStartDoesNotRunCommands() {
        XCTAssertThrowsError(try PlayerRotationControl.rotate(command: { _ in
            XCTFail("Cancelled rotation ran a command")
            return ""
        }, wait: { XCTFail("Cancelled rotation waited") }, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testCancellationAfterRequestRestoresModeAndViewport() {
        var cancelled = false
        var restored = false
        var viewportChecks = 0
        XCTAssertThrowsError(try PlayerRotationControl.rotate(command: { args in
            if args == ["wm", "user-rotation"] { return "free" }
            if args == ["wm", "user-rotation", "lock", "1"] {
                cancelled = true
                return ""
            }
            if args == ["wm", "user-rotation", "free"] { restored = true; return "" }
            XCTAssertEqual(args, ["dumpsys", "input"])
            viewportChecks += 1
            return self.viewport(0)
        }, wait: {}, isCancelled: { cancelled })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(restored)
        XCTAssertEqual(viewportChecks, 2, "Rollback must verify the viewport despite cancellation")
    }

    func testRestorationFailureIsNotHidden() {
        XCTAssertThrowsError(try PlayerRotationControl.rotate(command: { args in
            if args == ["wm", "user-rotation"] { return "free" }
            if args == ["wm", "user-rotation", "free"] { throw PlayerCommandError.failed(1) }
            if args == ["dumpsys", "input"] { return self.viewport(0) }
            return ""
        }, wait: {})) { XCTAssertEqual($0 as? PlayerRotationControlError, .restorationFailed) }
    }
}
