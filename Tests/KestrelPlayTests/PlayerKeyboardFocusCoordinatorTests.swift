import XCTest
import KestrelStream
@testable import KestrelPlay

@available(macOS 15, *)
@MainActor
final class PlayerKeyboardFocusCoordinatorTests: XCTestCase {
    func testFreshObservationPreparesInputAndSendsButQueuedExpiryDoesNot() async throws {
        var now = 1.0
        var preparations = 0
        var sends = 0
        let sent = expectation(description: "Fresh key sent")
        let coordinator = PlayerKeyboardFocusCoordinator(observe: { "editor" }, hostAllowsTyping: { true },
            beforeTyping: { preparations += 1; return true }, clock: { now }, send: { _ in
                sends += 1; sent.fulfill()
            }, onError: { _ in XCTFail("Unexpected error") })
        defer { coordinator.close() }
        await coordinator.refresh()
        XCTAssertEqual(preparations, 1)
        XCTAssertTrue(coordinator.submit(EmulatorKeyboardRequest(key: .enter)))
        await fulfillment(of: [sent], timeout: 2)
        await Task.yield()
        XCTAssertTrue(coordinator.submit(EmulatorKeyboardRequest(key: .left)))
        now = 2
        await Task.yield()
        XCTAssertEqual(sends, 1)
        XCTAssertFalse(coordinator.submit(EmulatorKeyboardRequest(key: .right)))
    }

    func testSlowObservationCannotBecomeFreshAtCompletion() async {
        var now = 1.0
        let coordinator = PlayerKeyboardFocusCoordinator(observe: { now = 2; return "editor" },
            hostAllowsTyping: { true }, beforeTyping: { XCTFail("Slow result authorized input"); return true },
            clock: { now }, send: { _ in XCTFail("Unexpected send") }, onError: { _ in XCTFail("Unexpected error") })
        defer { coordinator.close() }
        await coordinator.refresh()
        XCTAssertFalse(coordinator.submit(EmulatorKeyboardRequest(key: .enter)))
    }

    func testInvalidatedInflightObservationCannotAuthorizeAndOnlyOneQueryRuns() async {
        var continuation: CheckedContinuation<String?, Never>?
        var calls = 0
        let started = expectation(description: "Observation started")
        let coordinator = PlayerKeyboardFocusCoordinator(observe: {
            calls += 1
            return await withCheckedContinuation { continuation = $0; started.fulfill() }
        }, hostAllowsTyping: { true }, beforeTyping: { XCTFail("Stale observation applied"); return true },
            clock: { 1 }, send: { _ in XCTFail("Unexpected send") }, onError: { _ in XCTFail("Unexpected error") })
        let query = Task { await coordinator.refresh() }
        await fulfillment(of: [started], timeout: 2)
        await coordinator.refresh()
        XCTAssertEqual(calls, 1)
        coordinator.invalidate()
        continuation?.resume(returning: "editor")
        await query.value
        XCTAssertFalse(coordinator.submit(EmulatorKeyboardRequest(key: .enter)))
        coordinator.close()
    }

    func testObservationFailureRevokesPreviouslyValidFocusAndClosePreventsQueries() async {
        enum Failure: Error { case unavailable }
        var fail = false
        var queries = 0
        var preparations = 0
        let coordinator = PlayerKeyboardFocusCoordinator(observe: {
            queries += 1
            if fail { throw Failure.unavailable }
            return "editor"
        }, hostAllowsTyping: { true }, beforeTyping: { preparations += 1; return true },
            clock: { 1 }, send: { _ in XCTFail("No input should be sent") },
            onError: { _ in XCTFail("Observation failure must not become a transport error") })
        await coordinator.refresh()
        XCTAssertEqual(preparations, 1)
        fail = true
        await coordinator.refresh()
        XCTAssertFalse(coordinator.submit(EmulatorKeyboardRequest(key: .enter)))
        XCTAssertEqual(queries, 2)
        coordinator.close()
        fail = false
        await coordinator.refresh()
        XCTAssertEqual(queries, 2)
        XCTAssertFalse(coordinator.submit(EmulatorKeyboardRequest(key: .enter)))
    }

    func testHostFocusAndPreparationAreMandatory() async {
        var host = false
        var prepare = false
        var queries = 0
        let coordinator = PlayerKeyboardFocusCoordinator(observe: { queries += 1; return "editor" },
            hostAllowsTyping: { host }, beforeTyping: { prepare }, clock: { 1 },
            send: { _ in XCTFail("Unexpected send") }, onError: { _ in XCTFail("Unexpected error") })
        defer { coordinator.close() }
        await coordinator.refresh()
        XCTAssertEqual(queries, 0)
        host = true
        await coordinator.refresh()
        XCTAssertFalse(coordinator.submit(EmulatorKeyboardRequest(key: .enter)))
        prepare = true
        await coordinator.refresh()
        host = false
        XCTAssertFalse(coordinator.submit(EmulatorKeyboardRequest(key: .enter)))
        host = true
        XCTAssertFalse(coordinator.submit(EmulatorKeyboardRequest(key: .enter)))
    }
}
