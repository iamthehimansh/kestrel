import XCTest
@testable import KestrelStream
@testable import KestrelPlay

@available(macOS 15, *)
final class PlayerKeyboardDispatcherTests: XCTestCase {
    @MainActor
    func testBulkTextAndEditingKeyKeepExactOrderAsIndividualRequests() async throws {
        let text = "Kestrel keyboard 4"
        var received: [String] = []
        let sent = expectation(description: "Every character and editing key sent")
        sent.expectedFulfillmentCount = text.count + 1
        let dispatcher = PlayerKeyboardDispatcher(send: { request in
            received.append(request.message.text.isEmpty ? request.message.key : request.message.text)
            sent.fulfill()
        }, onError: { _ in XCTFail("Unexpected error") })
        defer { dispatcher.close() }
        XCTAssertTrue(dispatcher.submit(try EmulatorKeyboardRequest(text: text), isAuthorized: { true }))
        XCTAssertTrue(dispatcher.submit(EmulatorKeyboardRequest(key: .backspace), isAuthorized: { true }))
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertEqual(received, text.map(String.init) + ["Backspace"])
    }

    @MainActor
    func testWholeBatchCapacityIsCheckedBeforeSendingAnyPrefix() throws {
        var errors = 0
        let dispatcher = PlayerKeyboardDispatcher(capacity: 2, send: { _ in XCTFail("Rejected batch sent") },
            onError: { error in
                XCTAssertEqual(error as? PlayerKeyboardDispatchError, .overflow)
                errors += 1
            })
        XCTAssertFalse(dispatcher.submit(try EmulatorKeyboardRequest(text: "abc"), isAuthorized: { true }))
        XCTAssertEqual(errors, 1)
        XCTAssertFalse(dispatcher.submit(try EmulatorKeyboardRequest(text: "a"), isAuthorized: { true }))
        dispatcher.close()
    }

    @MainActor
    func testEachCharacterRechecksAuthorizationAndCloseRevokesRemainder() async throws {
        for close in [false, true] {
            var authorized = true
            var received: [String] = []
            let first = expectation(description: "First character sent")
            let drained = expectation(description: "Blocked send returned")
            var release: CheckedContinuation<Void, Never>?
            let dispatcher = PlayerKeyboardDispatcher(send: { request in
                received.append(request.message.text)
                if received.count == 1 {
                    await withCheckedContinuation { release = $0; first.fulfill() }
                    drained.fulfill()
                } else { XCTFail("Revoked character sent") }
            }, onError: { _ in XCTFail("Revocation must not report error") })
            XCTAssertTrue(dispatcher.submit(try EmulatorKeyboardRequest(text: "abc"), isAuthorized: { authorized }))
            await fulfillment(of: [first], timeout: 2)
            if close { dispatcher.close() } else { authorized = false }
            release?.resume()
            await fulfillment(of: [drained], timeout: 2)
            XCTAssertEqual(received, ["a"])
            XCTAssertFalse(dispatcher.submit(EmulatorKeyboardRequest(key: .enter), isAuthorized: { authorized }))
            dispatcher.close()
        }
    }

    @MainActor
    func testFocusChangeDropsQueuedKeysAndDoesNotOverlapInflightSend() async throws {
        var sends = 0
        var release: CheckedContinuation<Void, Never>?
        let first = expectation(description: "First send started")
        let second = expectation(description: "New focus send started")
        let dispatcher = PlayerKeyboardDispatcher(send: { _ in
            sends += 1
            if sends == 1 {
                await withCheckedContinuation { continuation in
                    release = continuation
                    first.fulfill()
                }
            } else { second.fulfill() }
        }, onError: { _ in XCTFail("Focus cancellation must not report a transport failure") })
        defer { dispatcher.close() }
        XCTAssertTrue(dispatcher.submit(try EmulatorKeyboardRequest(text: "a"), isAuthorized: { true }))
        await fulfillment(of: [first], timeout: 2)
        XCTAssertTrue(dispatcher.submit(try EmulatorKeyboardRequest(text: "stale"), isAuthorized: { true }))
        dispatcher.invalidateFocus()
        XCTAssertTrue(dispatcher.submit(try EmulatorKeyboardRequest(text: "b"), isAuthorized: { true }))
        await Task.yield()
        XCTAssertEqual(sends, 1)
        release?.resume()
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(sends, 2)
    }

    @MainActor
    func testOverflowClosesQueueRatherThanDroppingIndividualKeys() async throws {
        var sends = 0
        var release: CheckedContinuation<Void, Never>?
        var errors = 0
        let began = expectation(description: "Send began")
        let dispatcher = PlayerKeyboardDispatcher(capacity: 1, send: { _ in
            sends += 1
            await withCheckedContinuation { continuation in release = continuation; began.fulfill() }
        }, onError: { error in
            XCTAssertEqual(error as? PlayerKeyboardDispatchError, .overflow)
            errors += 1
        })
        XCTAssertTrue(dispatcher.submit(EmulatorKeyboardRequest(key: .enter), isAuthorized: { true }))
        await fulfillment(of: [began], timeout: 2)
        XCTAssertTrue(dispatcher.submit(EmulatorKeyboardRequest(key: .left), isAuthorized: { true }))
        XCTAssertFalse(dispatcher.submit(EmulatorKeyboardRequest(key: .right), isAuthorized: { true }))
        XCTAssertFalse(dispatcher.submit(EmulatorKeyboardRequest(key: .backspace), isAuthorized: { true }))
        release?.resume()
        await Task.yield()
        XCTAssertEqual(errors, 1)
        XCTAssertEqual(sends, 1)
        dispatcher.close()
    }

    @MainActor
    func testAuthorizationIsRecheckedBeforeQueuedKeyIsSent() async throws {
        var authorized = true
        var sends = 0
        let notSent = expectation(description: "Expired queued key is not sent")
        notSent.isInverted = true
        let dispatcher = PlayerKeyboardDispatcher(send: { _ in
            sends += 1
            notSent.fulfill()
        }, onError: { _ in XCTFail("Expired focus is not a transport error") })
        XCTAssertFalse(dispatcher.submit(EmulatorKeyboardRequest(key: .enter), isAuthorized: { false }))
        XCTAssertTrue(dispatcher.submit(EmulatorKeyboardRequest(key: .enter), isAuthorized: { authorized }))
        authorized = false
        await fulfillment(of: [notSent], timeout: 0.1)
        XCTAssertEqual(sends, 0)
        dispatcher.close()
    }

    @MainActor
    func testSendFailureClosesDispatcherAndReportsOnce() async throws {
        enum Failure: Error { case disconnected }
        let failed = expectation(description: "Failure reported")
        var sends = 0
        let dispatcher = PlayerKeyboardDispatcher(send: { _ in
            sends += 1
            throw Failure.disconnected
        }, onError: { error in
            XCTAssertTrue(error is Failure)
            failed.fulfill()
        })
        XCTAssertTrue(dispatcher.submit(EmulatorKeyboardRequest(key: .enter), isAuthorized: { true }))
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(dispatcher.submit(EmulatorKeyboardRequest(key: .enter), isAuthorized: { true }))
        XCTAssertEqual(sends, 1)
        dispatcher.close()
    }
}
