import AppKit
import Metal
import XCTest
import KestrelCore
import KestrelKeymap
@testable import KestrelPlay

final class PlayerFrameViewTests: XCTestCase {
    private func onMain(_ body: () throws -> Void) throws {
        if Thread.isMainThread { try body() }
        else { try DispatchQueue.main.sync(execute: body) }
    }

    func testKeyboardHookFailsClosedAndInvalidatesOnFocusLoss() throws {
        try onMain {
            _ = NSApplication.shared
            let view = try PlayerFrameView(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { view.setKeyboardHandler(nil); window.contentView = nil; window.close() }
            var sent = 0
            var invalidations = 0
            view.setKeyboardHandler({ _ in sent += 1; return true }, focusLost: { invalidations += 1 })
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
            view.keyDown(with: event)
            XCTAssertEqual(sent, 0, "Disconnected/unfocused view cannot forward keys")
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            XCTAssertEqual(invalidations, 1)
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            XCTAssertEqual(invalidations, 2)
            view.stopStream()
            XCTAssertEqual(invalidations, 3)
            _ = view.resignFirstResponder()
            XCTAssertEqual(invalidations, 4)
            view.setKeyboardHandler(nil)
            XCTAssertEqual(invalidations, 5)
            view.keyDown(with: event)
            XCTAssertEqual(sent, 0)
        }
    }

    func testDetachedViewPausesAndInvalidatesPreviousStream() throws {
        try onMain {
            let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let mailbox = PlayerFrameMailbox()
            let view = try PlayerFrameView(device: gpu, mailbox: mailbox)
            XCTAssertTrue(view.isPaused)
            let first = view.beginStream()
            let frame = try PlayerFrame(width: 2, height: 2, bytesPerRow: 8,
                sequence: 1, timestampMicroseconds: 0, rgba: Data(count: 16))
            XCTAssertTrue(mailbox.offer(frame, stream: first))
            let second = view.beginStream()
            XCTAssertNil(mailbox.takeLatest())
            XCTAssertFalse(mailbox.offer(frame, stream: first))
            XCTAssertTrue(mailbox.offer(frame, stream: second))
            view.stopStream()
            XCTAssertTrue(view.isPaused)
            XCTAssertFalse(mailbox.offer(frame, stream: second))
            XCTAssertEqual(mailbox.pendingCount, 0)
            XCTAssertNil(view.pixel(at: NSPoint(x: 1, y: 1)))
        }
    }

    func testAttachedWindowRendersMapsAndRedrawsOnlyOnChange() throws {
        try onMain {
            _ = NSApplication.shared
            let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let mailbox = PlayerFrameMailbox()
            let view = try PlayerFrameView(device: gpu, mailbox: mailbox)
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 400, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Kestrel rendering test"
            window.contentView = view
            defer {
                view.stopStream()
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
            window.orderBack(nil)
            let stream = view.beginStream()
            XCTAssertFalse(view.isPaused)
            // Drive draws explicitly so display-link scheduling does not affect assertions.
            view.isPaused = true
            let frame = try PlayerFrame(width: 4, height: 2, bytesPerRow: 16,
                sequence: 1, timestampMicroseconds: 0, rgba: Data(repeating: 255, count: 32))
            XCTAssertTrue(mailbox.offer(frame, stream: stream))
            func drawOnce() {
                view.isPaused = false
                view.draw()
                view.isPaused = true
            }
            let deadline = Date().addingTimeInterval(3)
            while view.submittedFrames == 0 && Date() < deadline {
                drawOnce()
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertEqual(view.submittedFrames, 1, "A real window must provide a drawable")
            let screenshot = try XCTUnwrap(view.screenshotFrame())
            XCTAssertEqual(screenshot.rgba, frame.rgba)
            XCTAssertEqual(screenshot.sequence, frame.sequence)
            let center = try XCTUnwrap(view.pixel(at: NSPoint(x: 200, y: 200)))
            XCTAssertEqual(center.x, 2)
            XCTAssertEqual(center.y, 1)
            XCTAssertNil(view.pixel(at: NSPoint(x: 200, y: 50)), "Bottom letterbox is not touchable")
            XCTAssertEqual(view.pixel(at: NSPoint(x: 10, y: 290))?.y, 0, "AppKit bottom-origin converts to guest top-origin")
            for _ in 0..<5 { drawOnce() }
            XCTAssertEqual(view.submittedFrames, 1, "Idle ticks must not submit the same frame")
            var touches: [TouchOp] = []
            view.setPointerHandler { touches += $0 }
            func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            }
            view.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 200, y: 50)))
            XCTAssertEqual(touches, [], "Letterbox press is ignored")
            view.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 200, y: 200)))
            XCTAssertEqual(touches, [.down(slot: 0, x: 2, y: 1)])
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            XCTAssertEqual(touches.last, .up(slot: 0), "Focus loss releases the held finger")
            let releasedCount = touches.count
            view.mouseUp(with: try mouse(.leftMouseUp, NSPoint(x: 200, y: 200)))
            XCTAssertEqual(touches.count, releasedCount)
            view.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 200, y: 200)))
            var replacement: [TouchOp] = []
            view.setPointerHandler { replacement += $0 }
            XCTAssertEqual(touches.last, .up(slot: 0), "Release is delivered to the old handler")
            XCTAssertTrue(replacement.isEmpty)
            view.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 200, y: 200)))
            view.setFrameSize(NSSize(width: 600, height: 400))
            XCTAssertEqual(replacement.last, .up(slot: 0), "Resize cancels before accepting more input")
            view.drawableSize = CGSize(width: 600, height: 400)
            view.mtkView(view, drawableSizeWillChange: view.drawableSize)
            let resizedDeadline = Date().addingTimeInterval(3)
            while view.submittedFrames == 1 && Date() < resizedDeadline {
                drawOnce()
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertEqual(view.submittedFrames, 2, "Resize redraws the retained image")
            XCTAssertEqual(view.pixel(at: NSPoint(x: 300, y: 200))?.x, 2)
            view.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 300, y: 200)))
            view.setRotation(.quarter)
            XCTAssertEqual(replacement.last, .up(slot: 0), "Rotation releases the old physical touch")
            XCTAssertNil(view.pixel(at: NSPoint(x: 300, y: 200)), "Input waits for rotated rendering")
            let beforeRotation = view.submittedFrames
            let rotationDeadline = Date().addingTimeInterval(3)
            while view.submittedFrames == beforeRotation && Date() < rotationDeadline {
                drawOnce()
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertEqual(view.displayedRotation, .quarter)
            XCTAssertEqual(view.submittedFrames, beforeRotation + 1)
            XCTAssertNil(view.pixel(at: NSPoint(x: 100, y: 200)), "Portrait side margin is not touchable")
            let rotatedPixel = try XCTUnwrap(view.pixel(at: NSPoint(x: 225, y: 375)))
            XCTAssertEqual(rotatedPixel.x, 3)
            XCTAssertEqual(rotatedPixel.y, 0)
            view.mouseDown(with: try mouse(.leftMouseDown, NSPoint(x: 225, y: 375)))
            XCTAssertEqual(replacement.last, .down(slot: 0, x: 3, y: 0))
            XCTAssertEqual(view.screenshotFrame()?.rgba, frame.rgba, "Rotation never rewrites the transport frame")
            view.stopStream()
            XCTAssertNil(view.pixel(at: NSPoint(x: 300, y: 200)))
            XCTAssertNil(view.screenshotFrame())
            XCTAssertEqual(screenshot.rgba, frame.rgba, "Retained screenshot survives stream shutdown")
        }
    }

    func testIdleDrawDoesNotConsumeFramesWithoutDrawable() throws {
        try onMain {
            let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let mailbox = PlayerFrameMailbox()
            let view = try PlayerFrameView(device: gpu, mailbox: mailbox)
            let stream = view.beginStream()
            let frame = try PlayerFrame(width: 2, height: 2, bytesPerRow: 8,
                sequence: 1, timestampMicroseconds: 0, rgba: Data(count: 16))
            XCTAssertTrue(mailbox.offer(frame, stream: stream))
            view.draw(in: view)
            XCTAssertEqual(view.submittedFrames, 0)
            XCTAssertEqual(mailbox.pendingCount, 1)
            view.stopStream()
        }
    }
}
