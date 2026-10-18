import Foundation
import XCTest
@testable import KestrelCore

final class EmulatorPlayerSessionTests: XCTestCase {
    private var directory: URL!
    private var store: InstanceStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("player-session-test-\(UUID())")
        store = InstanceStore(paths: KestrelPaths(root: directory),
                              sdk: AndroidSDK(root: directory.appendingPathComponent("absent-sdk")))
        _ = try store.create(name: "Session test")
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testCancelledBeforeStartDoesNotLaunchOrIssueTokens() throws {
        let session = EmulatorPlayerSession(store: store, index: 0, port: 8556)
        session.requestCancellation()
        XCTAssertThrowsError(try session.start()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: Launcher(store: store).pidFile(0).path))
        XCTAssertThrowsError(try session.token(for: .getScreenshot))
        try session.close()
        try session.close()
    }

    func testFailedStartCannotIssueTokensOrRestartSameSession() throws {
        let session = EmulatorPlayerSession(store: store, index: 0, port: 8556)
        XCTAssertThrowsError(try session.token(for: .streamScreenshot))
        XCTAssertThrowsError(try session.start())
        XCTAssertThrowsError(try session.start()) { error in
            XCTAssertTrue(String(describing: error).contains("only start once"))
        }
        XCTAssertThrowsError(try session.token(for: .getScreenshot))
        try session.close()
    }

    func testInvalidReadinessBudgetRejectedBeforeProfileAccess() {
        for timeout in [-1.0, 0, .nan, .infinity, 301] {
            let session = EmulatorPlayerSession(store: store, index: 999, port: 8556)
            XCTAssertThrowsError(try session.start(timeout: timeout)) { error in
                XCTAssertTrue(String(describing: error).contains("readiness timeout"))
            }
        }
    }

    func testCloseBeforeStartIsTerminal() throws {
        let session = EmulatorPlayerSession(store: store, index: 0, port: 8556)
        try session.close()
        XCTAssertThrowsError(try session.start()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertThrowsError(try session.token(for: .getScreenshot))
    }
}
