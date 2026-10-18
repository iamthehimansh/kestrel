import Foundation
import XCTest
@testable import KestrelCore

final class PlayerFrameTests: XCTestCase {
    private func frame(_ sequence: UInt64, width: Int = 2, height: Int = 2) throws -> PlayerFrame {
        try PlayerFrame(width: width, height: height, bytesPerRow: width * 4,
                        sequence: sequence, timestampMicroseconds: sequence * 1000,
                        rgba: Data(repeating: UInt8(sequence % 256), count: width * height * 4))
    }

    func testFrameCopiesExternallyMutableStorage() throws {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 1)
        defer { pointer.deallocate() }
        pointer.initializeMemory(as: UInt8.self, repeating: 7, count: 16)
        let external = Data(bytesNoCopy: pointer, count: 16, deallocator: .none)
        let owned = try PlayerFrame(width: 2, height: 2, bytesPerRow: 8,
                                    sequence: 1, timestampMicroseconds: 10, rgba: external)
        pointer.storeBytes(of: UInt8(99), as: UInt8.self)
        XCTAssertEqual(owned.rgba.first, 7, "Transport storage must not mutate a frame already handed to the renderer")
        var copy = owned.rgba
        copy[0] = 42
        XCTAssertEqual(owned.rgba.first, 7)
    }

    func testValidationRejectsUnsafeShapeAndLength() throws {
        for dimensions in [(0, 2, 8), (-1, 2, 8), (2, 2, 7), (2, 2, Int.max), (Int.max, 2, 8)] {
            XCTAssertThrowsError(try PlayerFrame(width: dimensions.0, height: dimensions.1,
                bytesPerRow: dimensions.2, sequence: 1, timestampMicroseconds: 0, rgba: Data(count: 16)))
        }
        XCTAssertThrowsError(try PlayerFrame(width: 2, height: 2, bytesPerRow: 8,
            sequence: 1, timestampMicroseconds: 0, rgba: Data(count: 15)))
        XCTAssertThrowsError(try PlayerFrame(width: 8192, height: 8192, bytesPerRow: 32768,
            sequence: 1, timestampMicroseconds: 0, rgba: Data()))
    }

    func testPaddedRowsPreserveTheirStride() throws {
        let owned = try PlayerFrame(width: 2, height: 2, bytesPerRow: 12,
                                    sequence: 0, timestampMicroseconds: 0, rgba: Data(count: 24))
        XCTAssertEqual(owned.bytesPerRow, 12)
        XCTAssertEqual(owned.rgba.count, 24)
    }

    func testSlowConsumerGetsOnlyLatestPendingFrame() throws {
        let mailbox = PlayerFrameMailbox()
        let stream = mailbox.beginStream()
        for n in 1...100 { XCTAssertTrue(mailbox.offer(try frame(UInt64(n)), stream: stream)) }
        XCTAssertEqual(mailbox.pendingCount, 1)
        XCTAssertEqual(mailbox.replacedCount, 99)
        XCTAssertEqual(mailbox.takeLatest()?.sequence, 100)
        XCTAssertEqual(mailbox.pendingCount, 0)
        XCTAssertNil(mailbox.takeLatest())
    }

    func testDuplicateAndOlderSequenceStayRejectedAfterTake() throws {
        let mailbox = PlayerFrameMailbox()
        let stream = mailbox.beginStream()
        XCTAssertTrue(mailbox.offer(try frame(5), stream: stream))
        _ = mailbox.takeLatest()
        XCTAssertFalse(mailbox.offer(try frame(5), stream: stream))
        XCTAssertFalse(mailbox.offer(try frame(4), stream: stream))
        XCTAssertTrue(mailbox.offer(try frame(6), stream: stream))
        XCTAssertEqual(mailbox.takeLatest()?.sequence, 6)
    }

    func testNewStreamRejectsLateCallbacksAndResetsSequence() throws {
        let mailbox = PlayerFrameMailbox()
        let old = mailbox.beginStream()
        XCTAssertTrue(mailbox.offer(try frame(100), stream: old))
        let current = mailbox.beginStream()
        XCTAssertNil(mailbox.takeLatest())
        XCTAssertFalse(mailbox.offer(try frame(101), stream: old))
        XCTAssertTrue(mailbox.offer(try frame(0, width: 1, height: 4), stream: current))
        let received = mailbox.takeLatest()
        XCTAssertEqual(received?.sequence, 0)
        XCTAssertEqual(received?.height, 4)
        mailbox.endStream(old)
        XCTAssertTrue(mailbox.offer(try frame(1), stream: current), "Old disconnect cannot close new stream")
        mailbox.endStream(current)
        XCTAssertNil(mailbox.takeLatest())
        XCTAssertFalse(mailbox.offer(try frame(2), stream: current))
    }

    func testConsumerFrameSurvivesReplacementAndClose() throws {
        let mailbox = PlayerFrameMailbox()
        let stream = mailbox.beginStream()
        XCTAssertTrue(mailbox.offer(try frame(1), stream: stream))
        let consumed = mailbox.takeLatest()
        XCTAssertTrue(mailbox.offer(try frame(2), stream: stream))
        mailbox.endStream(stream)
        XCTAssertEqual(consumed?.rgba.first, 1)
    }

    func testConcurrentOffersKeepHighestSequenceAndBoundedPendingCount() throws {
        let mailbox = PlayerFrameMailbox()
        let stream = mailbox.beginStream()
        let frames = try (0..<200).map { try frame(UInt64($0)) }
        DispatchQueue.concurrentPerform(iterations: frames.count) { i in
            _ = mailbox.offer(frames[i], stream: stream)
        }
        XCTAssertEqual(mailbox.pendingCount, 1)
        XCTAssertEqual(mailbox.takeLatest()?.sequence, 199)
    }
}
