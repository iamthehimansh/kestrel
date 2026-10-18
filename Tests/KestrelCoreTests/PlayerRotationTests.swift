import XCTest
@testable import KestrelCore

final class PlayerRotationTests: XCTestCase {
    func testUprightPixelOrderMatchesCapturedRotationConvention() throws {
        // Native 3x2 framebuffer: A B C / D E F.
        let expected: [PlayerRotation: [Int]] = [
            .natural: [0, 1, 2, 3, 4, 5],
            .quarter: [2, 5, 1, 4, 0, 3],
            .half: [5, 4, 3, 2, 1, 0],
            .threeQuarter: [3, 0, 4, 1, 5, 2]
        ]
        for rotation in PlayerRotation.allCases {
            let size = rotation.logicalSize(width: 3, height: 2)
            XCTAssertEqual(size.width, rotation.swapsAxes ? 2 : 3)
            XCTAssertEqual(size.height, rotation.swapsAxes ? 3 : 2)
            var physicalOrder: [Int] = []
            for y in 0..<size.height {
                for x in 0..<size.width {
                    let pixel = try XCTUnwrap(rotation.physicalPixel(x: x, y: y, width: 3, height: 2))
                    physicalOrder.append(pixel.y * 3 + pixel.x)
                }
            }
            XCTAssertEqual(physicalOrder, expected[rotation])
            XCTAssertEqual(Set(physicalOrder), Set(0..<6))
        }
    }

    func testRejectsOutsideLogicalBoundsAndInvalidDimensions() {
        for rotation in PlayerRotation.allCases {
            let size = rotation.logicalSize(width: 1280, height: 720)
            for (x, y) in [(-1, 0), (0, -1), (size.width, 0), (0, size.height), (Int.max, Int.max)] {
                XCTAssertNil(rotation.physicalPixel(x: x, y: y, width: 1280, height: 720))
            }
            XCTAssertNil(rotation.physicalPixel(x: 0, y: 0, width: 0, height: 720))
            XCTAssertNil(rotation.physicalPixel(x: 0, y: 0, width: 1280, height: -1))
            XCTAssertEqual(rotation.physicalPixel(x: 0, y: 0, width: 1, height: 1), .init(x: 0, y: 0))
        }
    }
}
