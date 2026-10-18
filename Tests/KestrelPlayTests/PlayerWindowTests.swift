import AppKit
import Metal
import XCTest
import KestrelCore
@testable import KestrelPlay

final class PlayerWindowTests: XCTestCase {
    private func onMain(_ body: () throws -> Void) throws {
        if Thread.isMainThread { try body() }
        else { try DispatchQueue.main.sync(execute: body) }
    }

    func testCommandsRequireConnectedBackendAndCloseInvalidatesStream() throws {
        try onMain {
            _ = NSApplication.shared
            let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let player = try PlayerWindowController(title: "Test instance", device: gpu)
            defer { player.close() }
            var actions: [PlayerWindowAction] = []
            var disconnects = 0
            player.onAction = { actions.append($0) }
            player.onDisconnect = { disconnects += 1 }
            XCTAssertFalse(player.perform(.home))
            let stream = player.beginConnection()
            XCTAssertFalse(player.perform(.home), "Handler alone must not enable unsupported actions")
            player.supportedActions = [.home, .back]
            XCTAssertFalse(player.perform(.screenshot))
            XCTAssertFalse(player.perform(.rotate))
            player.commandBusy = true
            XCTAssertFalse(player.perform(.home))
            player.commandBusy = false
            XCTAssertTrue(player.perform(.home))
            XCTAssertEqual(actions, [.home])
            player.setSidePanelVisible(false)
            XCTAssertFalse(player.sidePanelVisible)
            player.setSidePanelVisible(true)
            XCTAssertTrue(player.sidePanelVisible)
            let frame = try PlayerFrame(width: 1, height: 1, bytesPerRow: 4,
                sequence: 1, timestampMicroseconds: 0, rgba: Data(count: 4))
            XCTAssertTrue(player.frameView.mailbox.offer(frame, stream: stream))
            player.close()
            XCTAssertFalse(player.perform(.back))
            XCTAssertFalse(player.frameView.mailbox.offer(frame, stream: stream))
            XCTAssertEqual(disconnects, 1)
            player.close()
            XCTAssertEqual(disconnects, 1, "Closing twice cannot disconnect twice")
        }
    }

    func testCloseBeforeConnectionNotifiesSessionExactlyOnce() throws {
        try onMain {
            _ = NSApplication.shared
            let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let player = try PlayerWindowController(title: "Boot cancellation", device: gpu)
            var closes = 0
            player.onClose = { closes += 1 }
            player.disconnect(message: "Still booting")
            XCTAssertEqual(closes, 0)
            player.close()
            player.close()
            XCTAssertEqual(closes, 1)
        }
    }

    func testReconnectDoesNotRequestSessionShutdown() throws {
        try onMain {
            _ = NSApplication.shared
            let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let player = try PlayerWindowController(title: "Stream renewal", device: gpu)
            var closes = 0
            player.onClose = { closes += 1 }
            _ = player.beginConnection()
            _ = player.beginConnection()
            XCTAssertEqual(closes, 0)
            player.close()
            XCTAssertEqual(closes, 1)
        }
    }

    func testBootProgressEndsOnConnectionFailureAndClose() throws {
        try onMain {
            _ = NSApplication.shared
            let player = try PlayerWindowController(title: "Boot", device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            defer { player.close() }
            player.showBootProgress("Starting Android…")
            XCTAssertTrue(player.isBooting)
            XCTAssertFalse(player.isConnected)
            XCTAssertFalse(player.perform(.home))
            _ = player.beginConnection()
            XCTAssertFalse(player.isBooting)
            player.showBootProgress("Late startup callback")
            XCTAssertFalse(player.isBooting)
            player.disconnect(message: "Connection failed")
            XCTAssertFalse(player.isBooting)
            player.showBootProgress("Retrying…")
            XCTAssertTrue(player.isBooting)
            player.close()
            XCTAssertFalse(player.isBooting)
            player.showBootProgress("Late callback after close")
            XCTAssertFalse(player.isBooting)
        }
    }

    func testLandscapeCanvasFillsWidthExceptNarrowRightRail() throws {
        try onMain {
            _ = NSApplication.shared
            let player = try PlayerWindowController(title: "Landscape", device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            defer { player.close() }
            let window = try XCTUnwrap(player.window)
            let root = try XCTUnwrap(window.contentView)
            for size in [NSSize(width: 1000, height: 620), NSSize(width: 560, height: 360)] {
                window.setContentSize(size)
                player.showBootProgress("Starting Android…")
                root.layoutSubtreeIfNeeded()
                let canvas = try XCTUnwrap(player.frameView.superview)
                let rect = canvas.convert(canvas.bounds, to: root)
                XCTAssertEqual(rect.minX, 0, accuracy: 1)
                XCTAssertEqual(rect.width, root.bounds.width - 52, accuracy: 1)
                player.setSidePanelVisible(false)
                root.layoutSubtreeIfNeeded()
                XCTAssertEqual(canvas.bounds.width, root.bounds.width, accuracy: 1)
                player.setSidePanelVisible(true)
            }
        }
    }

    func testActionRailScrollsEveryControlIntoViewAtMinimumSize() throws {
        try onMain {
            _ = NSApplication.shared
            let player = try PlayerWindowController(title: "Short rail", device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            defer { player.close() }
            let window = try XCTUnwrap(player.window)
            let root = try XCTUnwrap(window.contentView)
            func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap(descendants)
            }
            let scroll = try XCTUnwrap(descendants(root).compactMap { $0 as? NSScrollView }
                .first { $0.identifier?.rawValue == "player.actionScroll" })
            let rail = try XCTUnwrap(scroll.documentView as? NSStackView)
            let buttons = rail.arrangedSubviews.compactMap { $0 as? NSButton }
            XCTAssertEqual(buttons.count, PlayerWindowAction.allCases.count + 1)
            for size in [NSSize(width: 1000, height: 620), NSSize(width: 560, height: 338),
                         NSSize(width: 560, height: 360), NSSize(width: 1000, height: 620)] {
                window.setContentSize(size)
                root.layoutSubtreeIfNeeded()
                XCTAssertEqual(scroll.bounds.width, 52, accuracy: 1)
                XCTAssertEqual(scroll.bounds.height, root.bounds.height - 44, accuracy: 1)
                XCTAssertGreaterThanOrEqual(rail.bounds.height, 400)
                for (index, button) in buttons.enumerated() {
                    XCTAssertTrue(button.superview === rail, "Stack must not detach clipped actions")
                    XCTAssertFalse(button.isHidden)
                    XCTAssertEqual(button.bounds.height, 36, accuracy: 0.5)
                    XCTAssertEqual(button.bounds.width, 36, accuracy: 0.5)
                    let rect = button.convert(button.bounds, to: rail)
                    if index > 0 {
                        let previous = buttons[index - 1].convert(buttons[index - 1].bounds, to: rail)
                        XCTAssertGreaterThanOrEqual(rect.minY, previous.maxY)
                    }
                    rail.scrollToVisible(rect)
                    root.layoutSubtreeIfNeeded()
                    XCTAssertTrue(rail.visibleRect.insetBy(dx: -1, dy: -1).contains(rect),
                                  "Every action, including mapping controls, must be reachable")
                }
                if size.height < 400 {
                    XCTAssertGreaterThan(rail.bounds.height, scroll.contentView.bounds.height)
                }
                player.setSidePanelVisible(false)
                root.layoutSubtreeIfNeeded()
                XCTAssertEqual(player.frameView.bounds.width, root.bounds.width, accuracy: 1)
                player.setSidePanelVisible(true)
                root.layoutSubtreeIfNeeded()
                XCTAssertEqual(scroll.bounds.width, 52, accuracy: 1)
            }
        }
    }

    func testDisplayResizeChangesHostWindowAndPreservesConnection() throws {
        try onMain {
            _ = NSApplication.shared
            let player = try PlayerWindowController(title: "Display size", device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            defer { player.close() }
            let window = try XCTUnwrap(player.window)
            let original = window.frame
            for factor: CGFloat in [0, -1, .nan, .infinity, 3] {
                XCTAssertFalse(player.resizeDisplay(by: factor))
                XCTAssertEqual(window.frame, original)
            }
            _ = player.beginConnection()
            XCTAssertTrue(player.resizeDisplay(by: 0.8))
            XCTAssertLessThan(window.frame.width, original.width)
            XCTAssertLessThan(window.frame.height, original.height)
            let smaller = window.frame
            XCTAssertTrue(player.resizeDisplay(by: 1.25))
            XCTAssertGreaterThan(window.frame.width, smaller.width)
            XCTAssertTrue(player.isConnected)
            for _ in 0..<12 { _ = player.resizeDisplay(by: 0.8) }
            XCTAssertGreaterThanOrEqual(window.frame.width, window.minSize.width)
            XCTAssertGreaterThanOrEqual(window.frame.height, window.minSize.height)
            player.close()
            XCTAssertFalse(player.resizeDisplay(by: 1.25))
        }
    }

    func testUnwiredControlsCannotClaimSuccess() throws {
        try onMain {
            _ = NSApplication.shared
            let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
            let player = try PlayerWindowController(title: "Unwired", device: gpu)
            defer { player.close() }
            _ = player.beginConnection()
            XCTAssertFalse(player.perform(.screenshot))
            player.disconnect(message: "Connection closed")
            XCTAssertTrue(player.frameView.isPaused)
            XCTAssertFalse(player.isConnected)
        }
    }
}
