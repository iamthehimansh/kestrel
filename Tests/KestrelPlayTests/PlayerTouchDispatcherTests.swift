import Foundation
import XCTest
import KestrelKeymap
@testable import KestrelPlay

private final class GatedTouchSink: TouchSink {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var sent: [TouchOp] = []
    private var closes = 0
    var fail = false

    func send(_ ops: [TouchOp]) throws {
        entered.signal()
        guard release.wait(timeout: .now() + 3) == .success else {
            throw TouchWriteError.timedOut
        }
        if fail { throw TouchWriteError.closed }
        lock.lock(); sent += ops; lock.unlock()
    }

    func close() {
        lock.lock(); closes += 1; lock.unlock()
        closed.signal()
    }

    var events: [TouchOp] { lock.lock(); defer { lock.unlock() }; return sent }
    var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }
}

final class PlayerTouchDispatcherTests: XCTestCase {
    func testMovesCoalesceWithoutCrossingGestureBoundaries() {
        let sink = GatedTouchSink()
        let dispatcher = PlayerTouchDispatcher(sink: sink, capacity: 8)
        defer { sink.release.signal(); dispatcher.close() }
        XCTAssertTrue(dispatcher.submit([.down(slot: 0, x: 10, y: 10)]))
        XCTAssertEqual(sink.entered.wait(timeout: .now() + 1), .success)
        for x in 11...1000 {
            XCTAssertTrue(dispatcher.submit([.move(slot: 0, x: x, y: 10)]))
        }
        XCTAssertEqual(dispatcher.pendingCount, 1)
        XCTAssertTrue(dispatcher.submit([.up(slot: 0), .down(slot: 0, x: 20, y: 20),
                                         .move(slot: 0, x: 30, y: 20), .up(slot: 0)]))
        XCTAssertEqual(dispatcher.pendingCount, 5)
        sink.release.signal()
        XCTAssertEqual(sink.entered.wait(timeout: .now() + 1), .success)
        sink.release.signal()
        let drained = expectation(description: "Drain complete")
        dispatcher.whenIdle { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(sink.events, [.down(slot: 0, x: 10, y: 10), .move(slot: 0, x: 1000, y: 10),
                                     .up(slot: 0), .down(slot: 0, x: 20, y: 20),
                                     .move(slot: 0, x: 30, y: 20), .up(slot: 0)])
        dispatcher.close()
        XCTAssertEqual(sink.closed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(sink.closeCount, 1)
    }

    func testOverflowClosesInsteadOfDroppingReleaseAndContinuing() {
        let sink = GatedTouchSink()
        let failure = expectation(description: "Overflow reported")
        let dispatcher = PlayerTouchDispatcher(sink: sink, capacity: 2) { error in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(error as? PlayerTouchDispatchError, .overflow)
            failure.fulfill()
        }
        defer { sink.release.signal(); dispatcher.close() }
        XCTAssertTrue(dispatcher.submit([.down(slot: 0, x: 1, y: 1)]))
        XCTAssertEqual(sink.entered.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(dispatcher.submit([.up(slot: 0), .down(slot: 0, x: 2, y: 2)]))
        XCTAssertFalse(dispatcher.submit([.up(slot: 0)]))
        XCTAssertFalse(dispatcher.submit([.move(slot: 0, x: 3, y: 3)]))
        sink.release.signal()
        XCTAssertEqual(sink.closed.wait(timeout: .now() + 1), .success)
        wait(for: [failure], timeout: 2)
        XCTAssertEqual(sink.events, [.down(slot: 0, x: 1, y: 1)])
        XCTAssertEqual(dispatcher.pendingCount, 0)
        XCTAssertEqual(sink.closeCount, 1)
    }

    func testWriteFailureClosesExactlyOnceAndRejectsFutureInput() {
        let sink = GatedTouchSink()
        sink.fail = true
        let failure = expectation(description: "Write error reported")
        let dispatcher = PlayerTouchDispatcher(sink: sink) { error in
            XCTAssertEqual(error as? TouchWriteError, .closed)
            failure.fulfill()
        }
        XCTAssertTrue(dispatcher.submit([.down(slot: 0, x: 1, y: 1)]))
        XCTAssertEqual(sink.entered.wait(timeout: .now() + 1), .success)
        sink.release.signal()
        XCTAssertEqual(sink.closed.wait(timeout: .now() + 1), .success)
        wait(for: [failure], timeout: 2)
        dispatcher.close()
        XCTAssertFalse(dispatcher.submit([.up(slot: 0)]))
        XCTAssertEqual(sink.closeCount, 1)
    }

    func testIdleNotificationIsSingleFlightUntilDelivered() {
        let sink = GatedTouchSink()
        let dispatcher = PlayerTouchDispatcher(sink: sink)
        defer { dispatcher.close() }
        let first = expectation(description: "First idle notification")
        let again = expectation(description: "Next idle notification")
        let register = {
            XCTAssertTrue(dispatcher.whenIdle { first.fulfill() })
            XCTAssertFalse(dispatcher.whenIdle { XCTFail("Duplicate idle waiter accepted") })
        }
        if Thread.isMainThread { register() }
        else { DispatchQueue.main.sync(execute: register) }
        wait(for: [first], timeout: 1)
        XCTAssertTrue(dispatcher.whenIdle { again.fulfill() })
        wait(for: [again], timeout: 1)
    }

    func testScheduledIdleCallbackWaitsForNewInflightWork() {
        let sink = GatedTouchSink()
        let dispatcher = PlayerTouchDispatcher(sink: sink)
        defer { sink.release.signal(); dispatcher.close() }
        let idle = expectation(description: "Truly idle")
        let mainTurn = expectation(description: "Main callback had opportunity to run")
        let register = {
            XCTAssertTrue(dispatcher.whenIdle {
                XCTAssertEqual(sink.events, [.down(slot: 0, x: 1, y: 1)])
                idle.fulfill()
            })
            XCTAssertTrue(dispatcher.submit([.down(slot: 0, x: 1, y: 1)]))
            DispatchQueue.main.async { mainTurn.fulfill() }
        }
        if Thread.isMainThread { register() }
        else { DispatchQueue.main.sync(execute: register) }
        XCTAssertEqual(sink.entered.wait(timeout: .now() + 1), .success)
        wait(for: [mainTurn], timeout: 1)
        sink.release.signal()
        wait(for: [idle], timeout: 1)
    }

    func testExplicitCloseDiscardsBacklogAndClosesAfterInflightWrite() {
        let sink = GatedTouchSink()
        let dispatcher = PlayerTouchDispatcher(sink: sink)
        XCTAssertTrue(dispatcher.submit([.down(slot: 0, x: 1, y: 1)]))
        XCTAssertEqual(sink.entered.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(dispatcher.submit([.move(slot: 0, x: 2, y: 2)]))
        dispatcher.close()
        dispatcher.close()
        XCTAssertFalse(dispatcher.submit([.up(slot: 0)]))
        sink.release.signal()
        XCTAssertEqual(sink.closed.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(sink.events, [.down(slot: 0, x: 1, y: 1)])
        XCTAssertEqual(sink.closeCount, 1)
    }
}
