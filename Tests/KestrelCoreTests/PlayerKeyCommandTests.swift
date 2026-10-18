import Foundation
import XCTest
@testable import KestrelCore

final class PlayerKeyCommandTests: XCTestCase {
    func testCommandsUseFixedArgumentVectorsNotShellStrings() {
        let expected: [(PlayerKeyCommand, String)] = [(.back, "4"), (.home, "3"), (.recents, "187"),
                                                    (.menu, "82"), (.volumeUp, "24"), (.volumeDown, "25")]
        for (command, code) in expected {
            XCTAssertEqual(command.arguments(serial: "emulator-5580"),
                           ["-s", "emulator-5580", "shell", "input", "keyevent", code])
        }
    }

    func testProcessSuccessAndFailureAreDistinguished() throws {
        try PlayerCommandProcess.run(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], timeout: 1)
        XCTAssertThrowsError(try PlayerCommandProcess.run(executable: URL(fileURLWithPath: "/usr/bin/false"),
                                                         arguments: [], timeout: 1))
    }

    func testHungCommandTimesOutWithoutWaitingForNaturalExit() {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try PlayerCommandProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                         arguments: ["10"], timeout: 0.1))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }

    func testDispatcherRejectsBacklogAndCompletesOnMainThread() {
        let entered = expectation(description: "Worker entered")
        let completed = expectation(description: "Command completed")
        let release = DispatchSemaphore(value: 0)
        let dispatcher = PlayerCommandDispatcher { command in
            XCTAssertFalse(Thread.isMainThread)
            if command == .back { throw PlayerCommandError.failed(1) }
            entered.fulfill()
            _ = release.wait(timeout: .now() + 3)
        }
        defer { release.signal(); dispatcher.close() }
        XCTAssertTrue(dispatcher.submit(.home) { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .failure = result { XCTFail("Unexpected command failure") }
            completed.fulfill()
        })
        wait(for: [entered], timeout: 2)
        XCTAssertFalse(dispatcher.submit(.back) { _ in XCTFail("Backlog must not execute") })
        release.signal()
        wait(for: [completed], timeout: 2)
        let next = expectation(description: "Slot available again")
        XCTAssertTrue(dispatcher.submit(.back) { result in
            guard case .failure(let error) = result else { return XCTFail("Error was hidden") }
            XCTAssertEqual(error as? PlayerCommandError, .failed(1))
            next.fulfill()
        })
        wait(for: [next], timeout: 2)
    }

    func testClosingDispatcherSuppressesLateCompletion() {
        let entered = expectation(description: "Worker entered")
        let finished = expectation(description: "Worker finished")
        let callback = expectation(description: "No late callback")
        callback.isInverted = true
        let release = DispatchSemaphore(value: 0)
        let dispatcher = PlayerCommandDispatcher { _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 3)
            finished.fulfill()
        }
        defer { release.signal(); dispatcher.close() }
        XCTAssertTrue(dispatcher.submit(.home) { _ in callback.fulfill() })
        wait(for: [entered], timeout: 2)
        dispatcher.close()
        release.signal()
        wait(for: [finished], timeout: 2)
        wait(for: [callback], timeout: 0.1)
        XCTAssertFalse(dispatcher.submit(.home) { _ in XCTFail("Closed worker accepted command") })
    }

    func testInvalidTimeoutRejectedBeforeLaunching() {
        for timeout in [0.0, -1, Double.nan, Double.infinity, 31] {
            XCTAssertThrowsError(try PlayerCommandProcess.run(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                                             arguments: [], timeout: timeout))
        }
    }
}
