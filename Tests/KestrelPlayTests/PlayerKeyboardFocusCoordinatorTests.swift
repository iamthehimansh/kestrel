import XCTest
@testable import KestrelStream
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

    func testFreshSameEditorObservationKeepsQueuedCharactersButChangedEditorRevokesThem() async throws {
        for changedEditor in [false, true] {
            var editor = "first"
            var now = 1.0
            var received: [String] = []
            var release: CheckedContinuation<Void, Never>?
            let began = expectation(description: "First character blocked")
            let finished = expectation(description: "First character returned")
            let remainder = expectation(description: "Same-editor remainder")
            remainder.isInverted = changedEditor
            let coordinator = PlayerKeyboardFocusCoordinator(observe: { editor }, hostAllowsTyping: { true },
                beforeTyping: { true }, clock: { now }, send: { request in
                    received.append(request.message.text)
                    if received.count == 1 {
                        await withCheckedContinuation { release = $0; began.fulfill() }
                        finished.fulfill()
                    } else { remainder.fulfill() }
                }, onError: { _ in XCTFail("Unexpected error") })
            await coordinator.refresh()
            XCTAssertTrue(coordinator.submit(try EmulatorKeyboardRequest(text: "ab")))
            await fulfillment(of: [began], timeout: 2)
            now = 1.2
            if changedEditor { editor = "second" }
            await coordinator.refresh()
            release?.resume()
            await fulfillment(of: [finished, remainder], timeout: changedEditor ? 0.1 : 2)
            XCTAssertEqual(received, changedEditor ? ["a"] : ["a", "b"])
            coordinator.close()
        }
    }

    func testGameplayMustReleaseBeforeTypingAndFreshRefreshDoesNotRestartIt() async throws {
        var gameplayActive = true
        var releasesGameplay = false
        var preparations = 0
        var now = 1.0
        let sent = expectation(description: "Typing after gameplay stopped")
        let coordinator = PlayerKeyboardFocusCoordinator(observe: { "editor" }, hostAllowsTyping: { true },
            beforeTyping: {
                preparations += 1
                if releasesGameplay { gameplayActive = false }
                return !gameplayActive
            }, clock: { now }, send: { _ in
                XCTAssertFalse(gameplayActive)
                sent.fulfill()
            }, onError: { _ in XCTFail("Unexpected error") })
        defer { coordinator.close() }
        await coordinator.refresh()
        XCTAssertFalse(coordinator.isTextInputFocused)
        XCTAssertFalse(coordinator.submit(EmulatorKeyboardRequest(key: .enter)))
        releasesGameplay = true
        await coordinator.refresh()
        XCTAssertTrue(coordinator.isTextInputFocused)
        XCTAssertFalse(gameplayActive)
        now = 1.1
        await coordinator.refresh()
        XCTAssertEqual(preparations, 2)
        XCTAssertTrue(coordinator.submit(EmulatorKeyboardRequest(key: .enter)))
        await fulfillment(of: [sent], timeout: 2)
        coordinator.invalidate()
        XCTAssertFalse(coordinator.isTextInputFocused)
        XCTAssertFalse(coordinator.submit(EmulatorKeyboardRequest(key: .enter)))
    }

    func testPreparationThatInvalidatesFocusCannotAuthorizeText() async {
        var coordinator: PlayerKeyboardFocusCoordinator!
        coordinator = PlayerKeyboardFocusCoordinator(observe: { "editor" }, hostAllowsTyping: { true },
            beforeTyping: { coordinator.invalidate(); return true }, clock: { 1 },
            send: { _ in XCTFail("Reentrant invalidation authorized text") },
            onError: { _ in XCTFail("Unexpected error") })
        defer { coordinator.close() }
        await coordinator.refresh()
        XCTAssertFalse(coordinator.isTextInputFocused)
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
