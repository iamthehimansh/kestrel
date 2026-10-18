import AppKit
import XCTest
import KestrelKeymap
@testable import KestrelPlay

final class PlayerKeymapOverlayTests: XCTestCase {
    private func onMain(_ work: () throws -> Void) rethrows {
        if Thread.isMainThread { try work() } else { try DispatchQueue.main.sync(execute: work) }
    }

    func testCancelDiscardsStagedChangesAndNeverSaves() throws {
        onMain {
            let original = Keymap(name: "Game", controls: [.tap(TapControl(key: "Q", at: NPoint(0.2, 0.4)))])
            let overlay = PlayerKeymapOverlay(keymap: original, aspect: 16.0 / 9)
            var dismissals = 0
            overlay.onSave = { _ in XCTFail("Cancel saved edits") }
            overlay.onDismiss = { dismissals += 1 }
            var staged = overlay.canvas.editor
            XCTAssertTrue(staged.rebind(0, to: "E"))
            staged.move(0, to: NPoint(0.7, 0.6))
            overlay.canvas.setKeymap(staged.keymap, aspect: overlay.canvas.aspect)
            overlay.cancelEditing()
            XCTAssertEqual(dismissals, 1)
            guard case .tap(let originalTap) = original.controls[0] else { return XCTFail("Expected tap") }
            XCTAssertEqual(originalTap.key, "Q")
            XCTAssertEqual(originalTap.at, NPoint(0.2, 0.4))
            XCTAssertTrue(overlay.canvas.overlaysLiveVideo)
        }
    }

    func testSavePersistsStagedKeymapAndDismissesOnlyOnSuccess() throws {
        onMain {
            let overlay = PlayerKeymapOverlay(keymap: Keymap(name: "Game", controls: []), aspect: 16.0 / 9)
            var staged = overlay.canvas.editor
            _ = staged.addTap(at: NPoint(0.4, 0.5), key: "Q")
            overlay.canvas.setKeymap(staged.keymap, aspect: overlay.canvas.aspect)
            var saved: Keymap?
            var dismissed = false
            overlay.onDismiss = { dismissed = true }
            enum SaveFailure: Error { case denied }
            overlay.onSave = { _ in throw SaveFailure.denied }
            XCTAssertFalse(overlay.commit())
            XCTAssertFalse(dismissed)
            XCTAssertTrue(overlay.status.stringValue.contains("Could not save"))
            overlay.onSave = { saved = $0 }
            XCTAssertTrue(overlay.commit())
            XCTAssertTrue(dismissed)
            XCTAssertEqual(saved?.controls.count, 1)
            guard let first = saved?.controls.first, case .tap(let savedTap) = first else { return XCTFail("Expected saved tap") }
            XCTAssertEqual(savedTap.key, "Q")
            XCTAssertEqual(savedTap.at, NPoint(0.4, 0.5))
        }
    }
}
