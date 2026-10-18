import AppKit
import Metal
import XCTest
import KestrelCore
@testable import KestrelPlay

@available(macOS 15, *)
final class NativePlayerSessionTests: XCTestCase {
    @MainActor
    func testVideoRPCSequenceStartsIndependentlyOfInitialScreenshotAndPriorRPC() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sequence-test-\(UUID())")
        let store = InstanceStore(paths: KestrelPaths(root: root), sdk: AndroidSDK(root: root))
        let controller = try NativePlayerSessionController(store: store, index: 0, port: 8556,
            title: "Sequence isolation", width: 2, height: 2, device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer { controller.player.close() }
        let mailbox = controller.player.frameView.mailbox
        func frame(_ sequence: UInt64) throws -> PlayerFrame {
            try PlayerFrame(width: 2, height: 2, bytesPerRow: 8, sequence: sequence,
                            timestampMicroseconds: sequence, rgba: Data(repeating: 255, count: 16))
        }
        let initial = controller.player.beginConnection()
        XCTAssertTrue(mailbox.offer(try frame(100), stream: initial))
        XCTAssertFalse(mailbox.offer(try frame(0), stream: initial), "Reproduces the old shared-counter rejection")
        let firstRPC = controller.beginVideoRPC()
        XCTAssertTrue(mailbox.offer(try frame(0), stream: firstRPC))
        XCTAssertFalse(mailbox.offer(try frame(101), stream: initial))
        XCTAssertTrue(mailbox.offer(try frame(80), stream: firstRPC))
        let renewed = controller.beginVideoRPC()
        XCTAssertTrue(mailbox.offer(try frame(0), stream: renewed))
        XCTAssertFalse(mailbox.offer(try frame(81), stream: firstRPC))
        XCTAssertTrue(controller.player.isConnected)
    }

    @MainActor
    func testFailedStartupFinishesCleanupAndReportsOnce() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-session-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InstanceStore(paths: KestrelPaths(root: root), sdk: AndroidSDK(root: root.appendingPathComponent("missing-sdk")))
        _ = try store.create(name: "Failure fixture")
        let controller = try NativePlayerSessionController(store: store, index: 0, port: 8556,
            title: "Failure fixture", width: 640, height: 360, device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer { controller.player.close() }
        let ended = expectation(description: "Failed startup cleaned up")
        ended.assertForOverFulfill = true
        controller.onReady = { XCTFail("Missing SDK cannot become ready") }
        controller.onStopped = { result in
            if case .success = result { XCTFail("Expected startup failure") }
            XCTAssertFalse(controller.player.isConnected)
            XCTAssertNil(Launcher(store: store).runningPID(0))
            ended.fulfill()
        }
        controller.start()
        controller.start()
        await fulfillment(of: [ended], timeout: 5)
        controller.stop()
    }

    @MainActor
    func testInputFailureIsReportedAsFailureNotCleanCancellation() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-input-failure-\(UUID())")
        let store = InstanceStore(paths: KestrelPaths(root: root), sdk: AndroidSDK(root: root.appendingPathComponent("missing-sdk")))
        let controller = try NativePlayerSessionController(store: store, index: 0, port: 8556,
            title: "Input failure", width: 640, height: 360, device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer { controller.player.close(); try? FileManager.default.removeItem(at: root) }
        let ended = expectation(description: "Input failure survives cleanup")
        var errors = 0
        controller.onCommandError = { _ in errors += 1 }
        controller.onStopped = { result in
            guard case .failure(let error) = result else {
                XCTFail("Input failure was reported as a clean stop")
                ended.fulfill()
                return
            }
            XCTAssertEqual(error as? TouchWriteError, .closed)
            ended.fulfill()
        }
        controller.start()
        controller.inputFailed(TouchWriteError.closed)
        controller.inputFailed(TouchWriteError.timedOut)
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(errors, 1)
    }

    @MainActor
    func testClosingImmediatelyCancelsStartupAndReportsOnce() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = InstanceStore(paths: KestrelPaths(root: root), sdk: AndroidSDK(root: root.appendingPathComponent("missing-sdk")))
        let controller = try NativePlayerSessionController(store: store, index: 0, port: 8556,
            title: "Cancellation fixture", width: 640, height: 360, device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let ended = expectation(description: "Cancelled startup cleaned up")
        ended.assertForOverFulfill = true
        controller.onReady = { XCTFail("Closed window became ready") }
        controller.onStopped = { result in
            if case .failure = result { XCTFail("Pre-start cancellation should be clean") }
            XCTAssertFalse(controller.player.isConnected)
            ended.fulfill()
        }
        var stoppingCalls = 0
        controller.onStopping = { stoppingCalls += 1 }
        XCTAssertThrowsError(try controller.acquireKeymapInput())
        XCTAssertNil(controller.keymapWindowState().frame)
        controller.start()
        controller.player.close()
        controller.player.close()
        await fulfillment(of: [ended], timeout: 5)
        XCTAssertEqual(stoppingCalls, 1)
        XCTAssertThrowsError(try controller.acquireKeymapInput())
        controller.releaseKeymapInput()
        XCTAssertNil(controller.keymapWindowState().frame)
    }
}
