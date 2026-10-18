import Foundation
import XCTest
@testable import KestrelPlay

final class TouchHandshakeTests: XCTestCase {
    func testCompleteReadyLineAndRejectsInvalidPrefix() throws {
        for (text, valid) in [("ready 1280 720\n", true), ("ready-made\n", false), ("error denied\n", false)] {
            let pipe = Pipe()
            defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
            try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            if valid {
                XCTAssertEqual(try TouchHandshake.read(from: pipe.fileHandleForReading, timeout: 0.1), "ready 1280 720")
            } else {
                XCTAssertThrowsError(try TouchHandshake.read(from: pipe.fileHandleForReading, timeout: 0.1))
            }
        }
    }

    func testSilentOpenPipeTimesOutWithoutBackgroundReader() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try TouchHandshake.read(from: pipe.fileHandleForReading, timeout: 0.05))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        try pipe.fileHandleForWriting.write(contentsOf: Data("ready retry\n".utf8))
        XCTAssertEqual(try TouchHandshake.read(from: pipe.fileHandleForReading, timeout: 0.1), "ready retry")
    }

    func testOversizedUnterminatedAndEOFRejected() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 65, count: 4096))
        XCTAssertThrowsError(try TouchHandshake.read(from: pipe.fileHandleForReading, timeout: 0.1))
        try pipe.fileHandleForWriting.close()
        XCTAssertThrowsError(try TouchHandshake.read(from: pipe.fileHandleForReading, timeout: 0.1))
    }
}
