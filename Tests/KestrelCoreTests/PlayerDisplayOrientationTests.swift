import XCTest
@testable import KestrelCore

final class PlayerDisplayOrientationTests: XCTestCase {
    private func line(_ rotation: Int, _ width: Int, _ height: Int) -> String {
        "  Viewport INTERNAL: displayId=0, uniqueId=local:123, port=0, orientation=\(rotation), logicalFrame=[0, 0, \(width), \(height)], physicalFrame=[0, 0, \(width), \(height)], deviceSize=[\(width), \(height)], isActive=[1]"
    }

    func testParsesRepeatedIdenticalActivePrimaryViewport() throws {
        for rotation in 0...3 {
            let width = rotation % 2 == 0 ? 1280 : 720
            let height = rotation % 2 == 0 ? 720 : 1280
            let row = line(rotation, width, height)
            let parsed = try PlayerDisplayOrientation.parse(row + "\n" + row)
            XCTAssertEqual(parsed.rotation.rawValue, rotation)
            XCTAssertEqual(parsed.width, width)
            XCTAssertEqual(parsed.height, height)
        }
    }

    func testRejectsMissingConflictingMalformedOrOversizedEvidence() {
        let row = line(0, 1280, 720)
        for text in ["", row.replacingOccurrences(of: "isActive=[1]", with: "isActive=[0]"),
                     row.replacingOccurrences(of: "displayId=0,", with: "displayId=1,"),
                     row + "\n" + line(1, 720, 1280), line(4, 1280, 720), line(0, 0, 720),
                     line(0, 8193, 720), row.replacingOccurrences(of: "logicalFrame=[0, 0,", with: "logicalFrame=[1, 0,"),
                     String(repeating: "x", count: 1_048_577)] {
            XCTAssertThrowsError(try PlayerDisplayOrientation.parse(text))
        }
    }
}
