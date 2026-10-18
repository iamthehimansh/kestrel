import Foundation
import XCTest
import KestrelKeymap
import KestrelCore
@testable import KestrelPlay

final class PlayerKeymapSinkTests: XCTestCase {
    private final class Sink: TouchSink {
        var events: [TouchOp] = []
        var closed = false
        func send(_ ops: [TouchOp]) throws { events += ops }
        func close() { closed = true }
    }

    func testRotatedLeaseTransformsCoordinatesAndRejectsWholeInvalidBatch() throws {
        let expected = [(0, 1), (1, 0), (2, 0), (1, 1)]
        for rotation in PlayerRotation.allCases {
            let sink = Sink()
            let dispatcher = PlayerTouchDispatcher(sink: sink)
            let lease = PlayerKeymapSink(dispatcher: dispatcher, geometry: (rotation, 3, 2))
            XCTAssertThrowsError(try lease.send([.down(slot: 1, x: 0, y: 0), .move(slot: 1, x: 99, y: 99)]))
            try lease.send([.down(slot: 0, x: 0, y: 1)])
            lease.close()
            let idle = expectation(description: "Rotated lease drained")
            XCTAssertTrue(dispatcher.whenIdle { idle.fulfill() })
            wait(for: [idle], timeout: 2)
            let point = expected[rotation.rawValue]
            XCTAssertEqual(sink.events, [.down(slot: 0, x: point.0, y: point.1), .up(slot: 0)])
            dispatcher.close()
            let closed = expectation(description: "Closed transport")
            XCTAssertTrue(dispatcher.whenIdle { closed.fulfill() })
            wait(for: [closed], timeout: 2)
        }
    }

    func testLeaseReleasesTouchesWithoutClosingTransportAndRejectsLateWrites() throws {
        let sink = Sink()
        let dispatcher = PlayerTouchDispatcher(sink: sink)
        let lease = PlayerKeymapSink(dispatcher: dispatcher)
        try lease.send([.down(slot: 0, x: 10, y: 20), .down(slot: 1, x: 30, y: 40), .up(slot: 1)])
        lease.close()
        lease.close()
        XCTAssertThrowsError(try lease.send([.down(slot: 0, x: 1, y: 2)]))
        let idle = expectation(description: "Lease release delivered")
        XCTAssertTrue(dispatcher.whenIdle { idle.fulfill() })
        wait(for: [idle], timeout: 2)
        XCTAssertEqual(sink.events, [.down(slot: 0, x: 10, y: 20), .down(slot: 1, x: 30, y: 40), .up(slot: 1), .up(slot: 0)])
        XCTAssertFalse(sink.closed)
        XCTAssertTrue(dispatcher.submit([.down(slot: 0, x: 50, y: 60), .up(slot: 0)]))
        let reused = expectation(description: "Direct pointer can reuse transport")
        XCTAssertTrue(dispatcher.whenIdle { reused.fulfill() })
        wait(for: [reused], timeout: 2)
        XCTAssertEqual(Array(sink.events.suffix(2)), [.down(slot: 0, x: 50, y: 60), .up(slot: 0)])
        dispatcher.close()
        let closed = expectation(description: "Transport closed")
        XCTAssertTrue(dispatcher.whenIdle { closed.fulfill() })
        wait(for: [closed], timeout: 2)
        XCTAssertTrue(sink.closed)
    }
}
