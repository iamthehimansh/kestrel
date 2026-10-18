import AppKit
import XCTest
import KestrelKeymap
@testable import KestrelPlay

final class PlayControllerFocusTests: XCTestCase {
    private final class Sink: TouchSink {
        var events: [TouchOp] = []
        func send(_ ops: [TouchOp]) throws { events += ops }
        func close() {}
    }

    func testNativeCursorClickAndDragShareSlotsWithMappedKeys() throws {
        let check = {
            _ = NSApplication.shared
            let sink = Sink()
            let keymap = Keymap(name: "Mouse", controls: [.tap(TapControl(key: "Space", at: NPoint(0.5, 0.5)))])
            let driver = Driver(engine: KeymapEngine(keymap: keymap, screenWidth: 640, screenHeight: 360), sink: sink)
            defer { driver.stop() }
            var focused = true
            let controller = PlayController(driver: driver, keymap: keymap, consolePort: 5580,
                windowProvider: { (CGRect(x: 0, y: 0, width: 640, height: 360), focused) })
            func mouse(_ type: CGEventType, _ x: Double, _ y: Double) throws -> CGEvent {
                try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: type,
                    mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left))
            }
            let down = try mouse(.leftMouseDown, 160, 90)
            let drag = try mouse(.leftMouseDragged, 320, 180)
            let up = try mouse(.leftMouseUp, 320, 180)
            driver.post(.keyDown("Space"))
            driver.sync { _ in }
            XCTAssertTrue(controller.handle(type: .leftMouseDown, event: down) == nil)
            XCTAssertTrue(controller.handle(type: .leftMouseDragged, event: drag) == nil)
            XCTAssertTrue(controller.handle(type: .leftMouseUp, event: up) == nil)
            driver.sync { _ in }
            XCTAssertEqual(sink.events, [.down(slot: 0, x: 320, y: 180), .down(slot: 1, x: 160, y: 90),
                                         .move(slot: 1, x: 320, y: 180), .up(slot: 1)])
            XCTAssertTrue(controller.handle(type: .leftMouseDown, event: down) == nil)
            focused = false
            XCTAssertTrue(controller.handle(type: .leftMouseUp, event: up) != nil)
            driver.sync { _ in }
            XCTAssertTrue(sink.events.suffix(2).contains(.up(slot: 0)))
            XCTAssertTrue(sink.events.suffix(2).contains(.up(slot: 1)))
        }
        if Thread.isMainThread { try check() } else { try DispatchQueue.main.sync(execute: check) }
    }

    func testNativeFocusIsCheckedBeforeEachKeyWithoutTimerTick() throws {
        let check = {
            _ = NSApplication.shared
            let sink = Sink()
            let keymap = Keymap(name: "Focus", controls: [.tap(TapControl(key: "Space", at: NPoint(0.5, 0.5)))])
            let driver = Driver(engine: KeymapEngine(keymap: keymap, screenWidth: 640, screenHeight: 360), sink: sink)
            defer { driver.stop() }
            var focused = true
            let controller = PlayController(driver: driver, keymap: keymap, consolePort: 5580,
                windowProvider: { (CGRect(x: 0, y: 0, width: 640, height: 360), focused) })
            let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true))
            let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: false))
            XCTAssertNil(controller.handle(type: .keyDown, event: down))
            driver.sync { _ in }
            XCTAssertEqual(sink.events.count, 1)
            focused = false
            XCTAssertNotNil(controller.handle(type: .keyUp, event: up))
            driver.sync { _ in }
            XCTAssertEqual(sink.events.count, 2, "Losing focus must release the held touch immediately")
            XCTAssertEqual(sink.events.last, .up(slot: 0))
            XCTAssertNotNil(controller.handle(type: .keyDown, event: down))
            driver.sync { _ in }
            XCTAssertEqual(sink.events.count, 2, "Unfocused input must not reach Android")
            focused = true
            down.flags = .maskCommand
            XCTAssertNotNil(controller.handle(type: .keyDown, event: down), "macOS shortcuts pass through")
            driver.sync { _ in }
            XCTAssertEqual(sink.events.count, 2)
        }
        if Thread.isMainThread { try check() } else { try DispatchQueue.main.sync(execute: check) }
    }
}
