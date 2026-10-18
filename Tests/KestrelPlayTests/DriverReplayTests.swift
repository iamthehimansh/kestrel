import Foundation
import XCTest
import KestrelKeymap
@testable import KestrelPlay

final class DriverReplayTests: XCTestCase {
    private final class Sink: TouchSink {
        var closed = false
        func send(_ ops: [TouchOp]) throws {}
        func close() { closed = true }
    }

    func testCancellationInterruptsLongEventGap() throws {
        let sink = Sink()
        let driver = Driver(engine: KeymapEngine(keymap: Keymap(name: "Replay", controls: []),
                                                 screenWidth: 640, screenHeight: 360), sink: sink)
        defer { driver.stop() }
        let began = ProcessInfo.processInfo.systemUptime
        let recording = InputRecording(entries: [.init(t: 60_000, event: .reset)])
        XCTAssertThrowsError(try driver.replay(recording, isCancelled: {
            ProcessInfo.processInfo.systemUptime - began >= 0.05
        })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.5)
    }

    func testRejectsUnsafeTimestampsBeforeReplay() throws {
        let sink = Sink()
        let driver = Driver(engine: KeymapEngine(keymap: Keymap(name: "Replay", controls: []),
                                                 screenWidth: 640, screenHeight: 360), sink: sink)
        defer { driver.stop() }
        for time in [-1.0, .nan, .infinity, 86_400_001] {
            XCTAssertThrowsError(try driver.replay(InputRecording(entries: [.init(t: time, event: .reset)]),
                                                   isCancelled: { false })) {
                XCTAssertTrue($0 is Driver.ReplayError)
            }
        }
        XCTAssertThrowsError(try driver.replay(InputRecording(entries: [
            .init(t: 10, event: .reset), .init(t: 9, event: .reset)
        ]), isCancelled: { false }))
    }

    func testReplayPropagatesSinkFailureInsteadOfReportingSuccess() throws {
        enum Failure: Error { case disconnected }
        final class FailingSink: TouchSink {
            func send(_ ops: [TouchOp]) throws { throw Failure.disconnected }
            func close() {}
        }
        let keymap = Keymap(name: "Replay", controls: [.tap(TapControl(key: "SPACE", at: NPoint(0.5, 0.5)))])
        let driver = Driver(engine: KeymapEngine(keymap: keymap, screenWidth: 640, screenHeight: 360),
                            sink: FailingSink())
        defer { driver.stop() }
        let recording = InputRecording(entries: [.init(t: 0, event: .keyDown("SPACE")),
                                                 .init(t: 100, event: .keyUp("SPACE"))])
        XCTAssertThrowsError(try driver.replay(recording, isCancelled: { false })) {
            XCTAssertTrue($0 is Failure)
        }
    }

    func testCancelledReplayDoesNotWaitForTail() throws {
        let driver = Driver(engine: KeymapEngine(keymap: Keymap(name: "Replay", controls: []),
                                                 screenWidth: 640, screenHeight: 360), sink: Sink())
        defer { driver.stop() }
        XCTAssertThrowsError(try driver.replay(InputRecording(), isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}
