import AppKit
import Metal
import XCTest
@testable import KestrelPlay

final class PlayerSidebarTests: XCTestCase {
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
