import XCTest
@testable import KestrelCore

final class PlayerGuestTextObserverTests: XCTestCase {
    private let window = "mCurrentFocus=Window{abc u0 org.kestrel.diagnostics/.KeyboardActivity}"
    private let editor = """
    Input method client state for android.view.inputmethod.InputMethodManager@123:
      mActive=true mRestartOnNextWindowFocus=false
      mServedView=android.widget.EditText{abc}
      mServedConnecting=false
      mCurrentEditorInfo:
        inputType=0x1 imeOptions=0x6
        packageName=org.kestrel.diagnostics fieldId=0x1
      mServedInputConnection=RemoteInputConnectionImpl{connection=EditableInputConnection@456 mDeactivateRequested=false mServedView=android.widget.EditText{abc}}
    """

    func testOneBudgetIsSharedAcrossThreeObservations() throws {
        var now = 1.0
        var calls: [[String]] = []
        var budgets: [Double] = []
        let result = try PlayerGuestTextObserver.inspect(timeout: 0.5, clock: { now }) { args, budget in
            calls.append(args); budgets.append(budget); now += 0.1
            return args == ["dumpsys", "input_method"] ? self.editor : self.window
        }
        XCTAssertEqual(result?.packageName, "org.kestrel.diagnostics")
        XCTAssertEqual(calls, [["dumpsys", "window", "displays"], ["dumpsys", "input_method"], ["dumpsys", "window", "displays"]])
        for (actual, expected) in zip(budgets, [0.5, 0.4, 0.3]) { XCTAssertEqual(actual, expected, accuracy: 0.00001) }
    }

    func testOverBudgetResponseCannotAuthorizeAndStopsFurtherCommands() {
        var now = 1.0
        var calls = 0
        XCTAssertThrowsError(try PlayerGuestTextObserver.inspect(timeout: 0.5, clock: { now }) { _, _ in
            calls += 1; now += 0.6; return self.window
        }) { XCTAssertEqual($0 as? PlayerCommandError, .timedOut) }
        XCTAssertEqual(calls, 1)
    }

    func testWindowChangeRejectsEditor() throws {
        var calls = 0
        let result = try PlayerGuestTextObserver.inspect(timeout: 0.5, clock: { 1 }) { args, _ in
            calls += 1
            if args == ["dumpsys", "input_method"] { return self.editor }
            return calls == 1 ? self.window : self.window.replacingOccurrences(of: "Window{abc", with: "Window{def")
        }
        XCTAssertNil(result)
    }

    func testCancellationStopsBeforeNextCommandOrReturningEvidence() async {
        for cancelAfter in [0, 1, 3] {
            let task = Task {
                var calls = 0
                do {
                    try withUnsafeCurrentTask { current in
                        if cancelAfter == 0 { current?.cancel() }
                        _ = try PlayerGuestTextObserver.inspect(timeout: 0.5, clock: { 1 }) { _, _ in
                            calls += 1
                            if calls == cancelAfter { current?.cancel() }
                            return ""
                        }
                    }
                    XCTFail("Cancelled observation returned evidence")
                } catch {
                    XCTAssertTrue(error is CancellationError)
                }
                XCTAssertEqual(calls, cancelAfter)
            }
            await task.value
        }
    }

    func testInvalidBudgetDoesNotRunCommand() {
        for timeout in [-1.0, 0, .nan, .infinity, 2.1] {
            XCTAssertThrowsError(try PlayerGuestTextObserver.inspect(timeout: timeout, clock: { 1 }) { _, _ in
                XCTFail("Invalid budget ran command"); return ""
            }) { XCTAssertEqual($0 as? PlayerCommandError, .invalidTimeout) }
        }
    }
}
