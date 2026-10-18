import AppKit
import Metal
import KestrelKeymap
import XCTest
@testable import KestrelPlay

final class PlayerSidebarTests: XCTestCase {
    private final class Sink: TouchSink {
        var events: [TouchOp] = []
        func send(_ ops: [TouchOp]) throws { events += ops }
        func close() {}
    }

    @MainActor
    func testPopoverReleasesHeldTouchesAndPassesSliderDragEvenWhenGuestKeepsFocus() throws {
        _ = NSApplication.shared
        let player = try PlayerWindowController(title: "Popover input", device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        defer { player.close() }
        let sink = Sink()
        let keymap = Keymap(name: "Popover", controls: [.tap(TapControl(key: "Space", at: NPoint(0.5, 0.5)))])
        let driver = Driver(engine: KeymapEngine(keymap: keymap, screenWidth: 640, screenHeight: 360), sink: sink)
        defer { driver.stop() }
        let controller = PlayController(driver: driver, keymap: keymap, consolePort: 5580,
            windowProvider: { (CGRect(x: 0, y: 0, width: 640, height: 360), true) })
        player.onGameplayInputBlocked = { controller.setInputSuspended($0) }
        player.setKeymappingEnabled(true)
        let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true))
        XCTAssertTrue(controller.handle(type: .keyDown, event: key) == nil)
        driver.sync { _ in }
        XCTAssertEqual(sink.events, [.down(slot: 0, x: 320, y: 180)])
        player.popoverWillShow(Notification(name: NSPopover.willShowNotification))
        XCTAssertTrue(player.isMappingPopoverOpen)
        XCTAssertEqual(sink.events.last, .up(slot: 0))
        let released = sink.events
        for type in [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: CGPoint(x: 200, y: 180), mouseButton: .left))
            XCTAssertTrue(controller.handle(type: type, event: event) != nil)
        }
        XCTAssertTrue(controller.handle(type: .keyDown, event: key) != nil)
        driver.sync { _ in }
        XCTAssertEqual(sink.events, released, "Popover actions must never reach Android")
        player.setHintOpacity(0.5)
        XCTAssertTrue(player.keymappingEnabled)
        player.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertFalse(player.isMappingPopoverOpen)
        XCTAssertTrue(controller.handle(type: .keyDown, event: key) == nil)
        driver.sync { _ in }
        XCTAssertEqual(sink.events.last, .down(slot: 0, x: 320, y: 180))
    }

    func testHintOpacityDoesNotDisableMappingOrDimVideo() throws {
        let check = {
            _ = NSApplication.shared
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let player = try PlayerWindowController(title: "Sidebar test", device: device)
            defer { player.window?.close() }
            var values: [Double] = []
            player.onHintOpacityChanged = { values.append($0) }
            player.setKeymappingEnabled(true)
            for value in [0.0, 0.5, 1.0] {
                player.setHintOpacity(value)
                XCTAssertEqual(player.hintOpacity, value)
                XCTAssertTrue(player.keymappingEnabled)
                XCTAssertEqual(player.frameView.alphaValue, 1)
            }
            player.setHintOpacity(-1)
            XCTAssertEqual(player.hintOpacity, 0)
            player.setHintOpacity(2)
            XCTAssertEqual(player.hintOpacity, 1)
            player.setHintOpacity(.nan)
            XCTAssertEqual(player.hintOpacity, 1)
            XCTAssertEqual(values, [0, 0.5, 1, 0, 1])
            player.setKeymappingEnabled(false)
            XCTAssertFalse(player.keymappingEnabled)
        }
        if Thread.isMainThread { try check() } else { try DispatchQueue.main.sync(execute: check) }
    }
}
