import XCTest
import KestrelCore
import KestrelKeymap
@testable import KestrelPlay

final class PlayerPointerTests: XCTestCase {
    private func viewport(width: Double = 400, height: Double = 400) throws -> PlayerViewport {
        try XCTUnwrap(PlayerViewport(imageWidth: 1280, imageHeight: 720,
                                    surfaceWidth: width, surfaceHeight: height))
    }

    func testDownMoveUpUsesAspectFitGuestPixels() throws {
        var pointer = PlayerPointer()
        XCTAssertEqual(pointer.updateViewport(try viewport()), [])
        XCTAssertEqual(pointer.begin(x: 200, y: 200), [.down(slot: 0, x: 640, y: 360)])
        XCTAssertEqual(pointer.move(x: 200, y: 200), [], "Duplicate coordinates produce no move")
        XCTAssertEqual(pointer.move(x: 300, y: 200), [.move(slot: 0, x: 960, y: 360)])
        XCTAssertEqual(pointer.end(), [.up(slot: 0)])
        XCTAssertEqual(pointer.end(), [], "Release occurs exactly once")
        XCTAssertEqual(pointer.move(x: 200, y: 200), [])
    }

    func testMarginsNeverCreateTouchesAndLeavingImageCancels() throws {
        var pointer = PlayerPointer()
        _ = pointer.updateViewport(try viewport())
        XCTAssertEqual(pointer.begin(x: 200, y: 10), [])
        XCTAssertEqual(pointer.move(x: 200, y: 200), [], "Dragging in from a margin cannot start a touch")
        _ = pointer.begin(x: 200, y: 200)
        XCTAssertEqual(pointer.move(x: 200, y: 10), [.up(slot: 0)])
        XCTAssertEqual(pointer.move(x: 200, y: 200), [], "Reentry requires a new mouse press")
    }

    func testGeometryChangesAndFocusLossReleaseHeldTouch() throws {
        var pointer = PlayerPointer()
        let original = try viewport()
        _ = pointer.updateViewport(original)
        _ = pointer.begin(x: 200, y: 200)
        XCTAssertEqual(pointer.updateViewport(original), [], "Same geometry must not interrupt a drag")
        XCTAssertEqual(pointer.updateViewport(try viewport(width: 800)), [.up(slot: 0)])
        XCTAssertEqual(pointer.move(x: 400, y: 200), [])
        _ = pointer.begin(x: 400, y: 200)
        XCTAssertEqual(pointer.cancel(), [.up(slot: 0)])
        XCTAssertEqual(pointer.cancel(), [])
        _ = pointer.begin(x: 400, y: 200)
        XCTAssertEqual(pointer.updateViewport(nil), [.up(slot: 0)])
        XCTAssertEqual(pointer.begin(x: 400, y: 200), [])
    }

    func testRepeatedPressReleasesPreviousFingerFirst() throws {
        var pointer = PlayerPointer()
        _ = pointer.updateViewport(try viewport())
        _ = pointer.begin(x: 200, y: 200)
        XCTAssertEqual(pointer.begin(x: 300, y: 200), [.up(slot: 0), .down(slot: 0, x: 960, y: 360)])
    }

    func testNonfiniteCoordinatesCancelRatherThanEmitInvalidPixels() throws {
        var pointer = PlayerPointer()
        _ = pointer.updateViewport(try viewport())
        XCTAssertEqual(pointer.begin(x: .nan, y: 200), [])
        _ = pointer.begin(x: 200, y: 200)
        XCTAssertEqual(pointer.move(x: .infinity, y: 200), [.up(slot: 0)])
    }
}
