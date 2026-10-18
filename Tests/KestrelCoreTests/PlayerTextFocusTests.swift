import XCTest
@testable import KestrelCore

final class PlayerTextFocusTests: XCTestCase {
    func testRequiresFreshGuestAndHostFocus() throws {
        var focus = PlayerTextFocus()
        XCTAssertNil(focus.permit(at: 1))
        focus.observe(editorID: "test-field", at: 1)
        XCTAssertNil(focus.permit(at: 1))
        focus.updateHost(focused: true, overlayOpen: false)
        XCTAssertNil(focus.permit(at: 1))
        focus.observe(editorID: "test-field", at: 1)
        let permit = try XCTUnwrap(focus.permit(at: 1.1))
        XCTAssertTrue(focus.permits(permit, at: 1.5))
        XCTAssertFalse(focus.permits(permit, at: 1.51))
        XCTAssertFalse(focus.permits(permit, at: 0.9))
        XCTAssertNil(focus.permit(at: .nan))
    }

    func testSwitchingFieldOrLosingHostFocusInvalidatesQueuedKeys() throws {
        var focus = PlayerTextFocus()
        focus.updateHost(focused: true, overlayOpen: false)
        focus.observe(editorID: "first", at: 1)
        let first = try XCTUnwrap(focus.permit(at: 1))
        focus.observe(editorID: "second", at: 1.1)
        XCTAssertFalse(focus.permits(first, at: 1.1))
        let second = try XCTUnwrap(focus.permit(at: 1.1))
        focus.updateHost(focused: false, overlayOpen: false)
        focus.updateHost(focused: true, overlayOpen: false)
        XCTAssertFalse(focus.permits(second, at: 1.2))
        XCTAssertNil(focus.permit(at: 1.2))
    }

    func testOverlayAndObservationGapCannotReviveOldPermit() throws {
        var focus = PlayerTextFocus()
        focus.updateHost(focused: true, overlayOpen: false)
        focus.observe(editorID: "first", at: 1)
        let first = try XCTUnwrap(focus.permit(at: 1))
        focus.observe(editorID: "first", at: 1.2)
        XCTAssertTrue(focus.permits(first, at: 1.3))
        focus.observe(editorID: "first", at: 2)
        XCTAssertFalse(focus.permits(first, at: 2))
        let refreshed = try XCTUnwrap(focus.permit(at: 2))
        focus.updateHost(focused: true, overlayOpen: true)
        focus.observe(editorID: "first", at: 2.1)
        XCTAssertNil(focus.permit(at: 2.1))
        focus.updateHost(focused: true, overlayOpen: false)
        XCTAssertFalse(focus.permits(refreshed, at: 2.2))
        XCTAssertNil(focus.permit(at: 2.2))
    }

    func testInvalidObservationsFailClosed() {
        for value in [nil, "", String(repeating: "x", count: 257)] as [String?] {
            var focus = PlayerTextFocus()
            focus.updateHost(focused: true, overlayOpen: false)
            focus.observe(editorID: value, at: 1)
            XCTAssertNil(focus.permit(at: 1))
        }
        for time in [-1.0, .nan, .infinity, 0.5] {
            var focus = PlayerTextFocus()
            focus.updateHost(focused: true, overlayOpen: false)
            focus.observe(editorID: "first", at: 1)
            focus.observe(editorID: "first", at: time)
            XCTAssertNil(focus.permit(at: 1.1))
        }
    }
}
