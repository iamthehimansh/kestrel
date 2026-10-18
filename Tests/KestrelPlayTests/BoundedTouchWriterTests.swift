import Darwin
import Foundation
import XCTest
@testable import KestrelPlay

final class BoundedTouchWriterTests: XCTestCase {
    func testWritesExactBytesAndClosesIdempotently() throws {
        let pipe = Pipe()
        let writer = try BoundedTouchWriter(handle: pipe.fileHandleForWriting)
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        let bytes = Data("down 0 12 34\nup 0\n".utf8)
        try writer.write(bytes, timeout: 0.1)
        XCTAssertEqual(try pipe.fileHandleForReading.read(upToCount: bytes.count), bytes)
        writer.close()
        writer.close()
        XCTAssertThrowsError(try writer.write(bytes, timeout: 0.1))
    }

    func testStalledReaderTimesOutAndPoisonsPartialCommandStream() throws {
        let pipe = Pipe()
        let writer = try BoundedTouchWriter(handle: pipe.fileHandleForWriting)
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try writer.write(Data(repeating: 65, count: 1_048_576), timeout: 0.1)) { error in
            XCTAssertEqual(error as? TouchWriteError, .timedOut)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertThrowsError(try writer.write(Data("reset\n".utf8), timeout: 0.1)) { error in
            XCTAssertEqual(error as? TouchWriteError, .closed)
        }
        // The incomplete stream must terminate with EOF rather than be reused.
        XCTAssertGreaterThan(pipe.fileHandleForReading.readDataToEndOfFile().count, 0)
    }

    func testClosedReaderReportsFailureWithoutSIGPIPE() throws {
        let pipe = Pipe()
        let writer = try BoundedTouchWriter(handle: pipe.fileHandleForWriting)
        defer { writer.close() }
        try pipe.fileHandleForReading.close()
        XCTAssertThrowsError(try writer.write(Data("up 0\n".utf8), timeout: 0.1))
        XCTAssertThrowsError(try writer.write(Data("reset\n".utf8), timeout: 0.1)) { error in
            XCTAssertEqual(error as? TouchWriteError, .closed)
        }
    }

    func testInvalidDeadlineAndOversizeAreRejectedBeforeWriting() throws {
        let pipe = Pipe()
        let writer = try BoundedTouchWriter(handle: pipe.fileHandleForWriting)
        defer { writer.close(); try? pipe.fileHandleForReading.close() }
        for timeout in [0.0, -1, Double.nan, Double.infinity, 2] {
            XCTAssertThrowsError(try writer.write(Data([1]), timeout: timeout))
        }
        XCTAssertThrowsError(try writer.write(Data(count: 1_048_577), timeout: 0.1))
        try writer.write(Data([42]), timeout: 0.1)
        XCTAssertEqual(try pipe.fileHandleForReading.read(upToCount: 1), Data([42]))
    }
}
