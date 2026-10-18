import AppKit
import XCTest
@testable import KestrelPlay

final class PlayerCursorTests: XCTestCase {
    func testGoldCursorHasTipHotspotAndVisibleGoldPixels() throws {
        try DispatchQueue.main.syncIfNeeded {
            let cursor = PlayerCursor.gold
            XCTAssertEqual(cursor.hotSpot, NSPoint(x: 3, y: 2))
            XCTAssertEqual(cursor.image.size, NSSize(width: 24, height: 32))
            let data = try XCTUnwrap(cursor.image.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            var goldPixels = 0
            var outlinePixels = 0
            var transparentPixels = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.alphaComponent < 0.1 { transparentPixels += 1 }
                    if color.alphaComponent > 0.9, color.redComponent > 0.9,
                       color.greenComponent > 0.6, color.greenComponent < 0.85,
                       color.blueComponent < 0.3 { goldPixels += 1 }
                    if color.alphaComponent > 0.9, color.redComponent < 0.3,
                       color.greenComponent < 0.3, color.blueComponent < 0.3 { outlinePixels += 1 }
                }
            }
            XCTAssertGreaterThan(goldPixels, 80)
            XCTAssertGreaterThan(outlinePixels, 20)
            XCTAssertGreaterThan(transparentPixels, 100)
        }
    }
}

private extension DispatchQueue {
    func syncIfNeeded(_ body: () throws -> Void) rethrows {
        if Thread.isMainThread { try body() }
        else { try sync(execute: body) }
    }
}
