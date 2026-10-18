import AppKit
import XCTest
import KestrelKeymap
@testable import KestrelPlay

final class HintOverlayTests: XCTestCase {
    private func onMain(_ body: () throws -> Void) rethrows {
        if Thread.isMainThread { try body() }
        else { try DispatchQueue.main.sync(execute: body) }
    }

    private func keymap() -> Keymap {
        Keymap(name: "Hints", controls: [.tap(TapControl(key: "Space", at: NPoint(0.5, 0.5)))])
    }

    func testNativeHintsAreClickThroughChildrenAndPreserveOpacityAcrossHideAndResize() throws {
        try onMain {
            _ = NSApplication.shared
            let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 360),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            defer { parent.close() }
            parent.orderFront(nil)
            let overlay = HintOverlay(keymap: keymap(), parentWindow: parent)
            defer { overlay.close() }
            let frame = CGRect(x: 100, y: 150, width: 640, height: 360)
            let keyWindow = NSApp.keyWindow
            overlay.setOpacity(0.5)
            overlay.update(frame: frame, visible: true, look: false)
            XCTAssertTrue(overlay.window.parent === parent)
            XCTAssertEqual(parent.childWindows?.count, 1)
            XCTAssertTrue(overlay.window.isVisible)
            XCTAssertTrue(overlay.window.ignoresMouseEvents)
            XCTAssertFalse(overlay.window.canBecomeKey)
            XCTAssertFalse(overlay.window.canBecomeMain)
            XCTAssertTrue(NSApp.keyWindow === keyWindow)
            XCTAssertEqual(overlay.window.level, parent.level)
            XCTAssertTrue(overlay.window.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertFalse(overlay.window.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertFalse(overlay.window.collectionBehavior.contains(.stationary))
            for opacity in [0.0, 0.5, 1.0] {
                overlay.setOpacity(opacity)
                overlay.update(frame: frame, visible: true, look: false)
                XCTAssertEqual(overlay.window.alphaValue, opacity)
                XCTAssertTrue(overlay.window.parent === parent)
            }
            overlay.setOpacity(0.5)
            overlay.setOpacity(.nan)
            overlay.setOpacity(.infinity)
            XCTAssertEqual(overlay.window.alphaValue, 0.5)
            overlay.setOpacity(-1)
            XCTAssertEqual(overlay.window.alphaValue, 0)
            overlay.setOpacity(2)
            XCTAssertEqual(overlay.window.alphaValue, 1)
            overlay.setOpacity(0.5)
            overlay.update(frame: frame, visible: false, look: false)
            XCTAssertFalse(overlay.window.isVisible)
            XCTAssertNil(overlay.window.parent)
            let resized = CGRect(x: 200, y: 250, width: 480, height: 270)
            overlay.update(frame: resized, visible: true, look: true)
            XCTAssertEqual(overlay.window.frame.size, resized.size)
            XCTAssertEqual(overlay.window.frame.minX, resized.minX)
            XCTAssertEqual(overlay.window.frame.maxY, (NSScreen.screens.first?.frame.height ?? 0) - resized.minY)
            XCTAssertTrue(overlay.window.parent === parent)
            XCTAssertEqual(overlay.window.alphaValue, 0.5)
            overlay.toggleHidden()
            overlay.update(frame: resized, visible: true, look: true)
            XCTAssertFalse(overlay.window.isVisible)
            XCTAssertNil(overlay.window.parent)
            overlay.toggleHidden()
            overlay.update(frame: resized, visible: true, look: false)
            XCTAssertTrue(overlay.window.isVisible)
            XCTAssertEqual(overlay.window.alphaValue, 0.5)
            parent.orderOut(nil)
            overlay.update(frame: resized, visible: true, look: false)
            XCTAssertFalse(overlay.window.isVisible, "Hidden native parent must never leave floating hints")
            parent.orderFront(nil)
            overlay.update(frame: resized, visible: true, look: false)
            overlay.close()
            XCTAssertNil(overlay.window.parent)
            overlay.update(frame: resized, visible: true, look: false)
            XCTAssertFalse(overlay.window.isVisible, "Late updates must not resurrect stopped hints")
        }
    }

    func testLegacyHintsRetainExternalEmulatorWindowPolicy() {
        onMain {
            _ = NSApplication.shared
            let overlay = HintOverlay(keymap: keymap())
            defer { overlay.close() }
            XCTAssertNil(overlay.window.parent)
            XCTAssertEqual(overlay.window.level, .floating)
            XCTAssertTrue(overlay.window.collectionBehavior.contains(.canJoinAllSpaces))
            XCTAssertTrue(overlay.window.collectionBehavior.contains(.fullScreenAuxiliary))
            XCTAssertTrue(overlay.window.collectionBehavior.contains(.stationary))
        }
    }

    /// Opt in on an interactive desktop: this enters a real fullscreen Space, not a
    /// fabricated styleMask. It requires neither Android nor Accessibility permission.
    @MainActor
    func testNativeHintsSurviveRealFullscreenRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["KESTREL_FULLSCREEN_TESTS"] == "1" else {
            throw XCTSkip("Run with KESTREL_FULLSCREEN_TESTS=1 on an interactive desktop")
        }
        _ = NSApplication.shared
        let originalPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(originalPolicy) }
        let parent = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 640, height: 360),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.collectionBehavior = [.fullScreenPrimary]
        let overlay = HintOverlay(keymap: keymap(), parentWindow: parent)
        defer { overlay.close(); parent.close() }
        parent.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(parent.isKeyWindow, "Fullscreen fixture must own keyboard focus before attaching hints")
        func updateHints() {
            let rect = parent.convertToScreen(parent.contentView!.bounds)
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            overlay.update(frame: CGRect(x: rect.minX, y: screenHeight - rect.maxY,
                                         width: rect.width, height: rect.height), visible: true, look: false)
        }
        func transition(to fullscreen: Bool) async throws {
            let notification = fullscreen ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification
            let finished = expectation(forNotification: notification, object: parent)
            parent.toggleFullScreen(nil)
            await fulfillment(of: [finished], timeout: 8)
            XCTAssertEqual(parent.styleMask.contains(.fullScreen), fullscreen)
        }
        overlay.setOpacity(0.5)
        updateHints()
        try await transition(to: true)
        for value in [0.0, 0.5, 1.0] {
            overlay.setOpacity(value)
            updateHints()
            XCTAssertTrue(overlay.window.parent === parent)
            XCTAssertTrue(overlay.window.isVisible)
            XCTAssertTrue(overlay.window.isOnActiveSpace)
            XCTAssertEqual(overlay.window.alphaValue, value)
            XCTAssertTrue(parent.isKeyWindow, "Hints must not take gameplay keyboard focus")
        }
        try await transition(to: false)
        updateHints()
        XCTAssertTrue(overlay.window.parent === parent)
        XCTAssertTrue(overlay.window.isVisible)
        XCTAssertTrue(overlay.window.isOnActiveSpace)
        XCTAssertEqual(overlay.window.alphaValue, 1)
    }
}
