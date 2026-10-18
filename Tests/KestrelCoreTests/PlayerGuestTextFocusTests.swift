import XCTest
@testable import KestrelCore

final class PlayerGuestTextFocusTests: XCTestCase {
    private let current = """
    Input method client state for android.view.inputmethod.InputMethodManager@123:
      mActive=true mRestartOnNextWindowFocus=false mBindSequence=1
      mServedView=android.widget.EditText{abc}
      mServedConnecting=false
      mCurrentEditorInfo:
        inputType=0x80001 imeOptions=0x6 privateImeOptions=null
        packageName=org.kestrel.diagnostics fieldId=0xffffffff
      mServedInputConnection=RemoteInputConnectionImpl{connection=EditableInputConnection@456 mDeactivateRequested=false mServedView=android.widget.EditText{abc}}
      mCursorSelStart=0
    """

    func testAcceptsCurrentActiveEditorAndIgnoresHistory() throws {
        let result = try XCTUnwrap(PlayerGuestTextFocus.parse("History:\n    inputType=0x0 packageName=old.app\n" + current))
        XCTAssertEqual(result.packageName, "org.kestrel.diagnostics")
        XCTAssertEqual(result.editorID.count, 64)
        XCTAssertEqual(PlayerGuestTextFocus.parse(current), result)
        XCTAssertNotEqual(PlayerGuestTextFocus.parse(current.replacingOccurrences(of: "EditText{abc}", with: "EditText{def}"))?.editorID, result.editorID)
    }

    func testRejectsInactiveAmbiguousOrMismatchedClients() {
        for invalid in [
            current.replacingOccurrences(of: "mActive=true", with: "mActive=false"),
            current.replacingOccurrences(of: "mServedConnecting=false", with: "mServedConnecting=true"),
            current.replacingOccurrences(of: "mDeactivateRequested=false", with: "mDeactivateRequested=true"),
            current.replacingOccurrences(of: "inputType=0x80001", with: "inputType=0x0"),
            current.replacingOccurrences(of: "mServedView=android.widget.EditText{abc}}", with: "mServedView=null}"),
            current.replacingOccurrences(of: "  mCurrentEditorInfo:", with: "  mCurrentEditorInfo: null"),
            current + "\n" + current,
            current + "\n  mServedConnecting=false",
            String(repeating: "x", count: 1_048_577), ""
        ] {
            XCTAssertNil(PlayerGuestTextFocus.parse(invalid))
        }
    }

    func testRequiresMatchingUnambiguousCurrentWindow() throws {
        let window = "  mCurrentFocus=Window{abc123 u0 org.kestrel.diagnostics/.KeyboardActivity}"
        XCTAssertNotNil(PlayerGuestTextFocus.validated(inputMethodDump: current, windowDump: window))
        for invalid in ["", "mCurrentFocus=null", window + "\n" + window,
                        window.replacingOccurrences(of: "org.kestrel.diagnostics/", with: "other.app/"),
                        "mFocusedApp=org.kestrel.diagnostics", String(repeating: "x", count: 1_048_577)] {
            XCTAssertNil(PlayerGuestTextFocus.validated(inputMethodDump: current, windowDump: invalid))
        }
        XCTAssertNil(PlayerGuestTextFocus.validated(inputMethodDump: "", windowDump: window))
    }

    func testWindowMustRemainIdenticalAcrossEditorObservation() {
        let before = "mCurrentFocus=Window{abc123 u0 org.kestrel.diagnostics/.KeyboardActivity}"
        XCTAssertNotNil(PlayerGuestTextFocus.validated(inputMethodDump: current, windowBefore: before, windowAfter: before))
        for after in [before.replacingOccurrences(of: "abc123", with: "def456"),
                      before.replacingOccurrences(of: "KeyboardActivity", with: "AnotherActivity"),
                      "mCurrentFocus=null", "", before + "\n" + before] {
            XCTAssertNil(PlayerGuestTextFocus.validated(inputMethodDump: current, windowBefore: before, windowAfter: after))
        }
        XCTAssertNil(PlayerGuestTextFocus.validated(inputMethodDump: current, windowBefore: "", windowAfter: before))
    }

    func testHistoricalEditorWithoutCurrentClientCannotAuthorize() {
        XCTAssertNil(PlayerGuestTextFocus.parse("mCurEditorInfo:\n    inputType=0x80001 packageName=org.kestrel.diagnostics\n"))
    }
}
