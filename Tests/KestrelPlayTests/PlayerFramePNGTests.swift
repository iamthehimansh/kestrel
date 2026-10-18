import Foundation
import CoreGraphics
import ImageIO
import XCTest
import KestrelCore
@testable import KestrelPlay

final class PlayerFramePNGTests: XCTestCase {
    private func frame() throws -> PlayerFrame {
        try PlayerFrame(width: 2, height: 2, bytesPerRow: 12, sequence: 1,
                        timestampMicroseconds: 0,
                        rgba: Data([255,0,0,255, 0,255,0,255, 19,19,19,19,
                                    0,0,255,255, 255,255,255,255, 29,29,29,29]))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let cropped = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }

    func testPNGPreservesDimensionsColorsOrientationAndPaddedStride() throws {
        let data = try PlayerFramePNG.encode(frame())
        XCTAssertTrue(data.starts(with: [137,80,78,71,13,10,26,10]))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 2)
        XCTAssertEqual(image.height, 2)
        XCTAssertEqual(try pixel(image, x: 0, y: 0), [255,0,0,255])
        XCTAssertEqual(try pixel(image, x: 1, y: 0), [0,255,0,255])
        XCTAssertEqual(try pixel(image, x: 0, y: 1), [0,0,255,255])
        XCTAssertEqual(try pixel(image, x: 1, y: 1), [255,255,255,255])
    }

    func testRotatedPNGMatchesUprightPixelOrderAndDimensions() throws {
        let colors: [[UInt8]] = [[255,0,0,255], [0,255,0,255], [0,0,255,255],
                                  [255,255,0,255], [255,0,255,255], [0,255,255,255]]
        var bytes: [UInt8] = colors.prefix(3).flatMap { $0 }
        bytes.append(contentsOf: [7,7,7,7])
        bytes.append(contentsOf: colors.suffix(3).flatMap { $0 })
        bytes.append(contentsOf: [8,8,8,8])
        let frame = try PlayerFrame(width: 3, height: 2, bytesPerRow: 16, sequence: 1,
                                    timestampMicroseconds: 0, rgba: Data(bytes))
        let orders = [[0,1,2,3,4,5], [2,5,1,4,0,3], [5,4,3,2,1,0], [3,0,4,1,5,2]]
        for rotation in PlayerRotation.allCases {
            let data = try PlayerFramePNG.encode(frame, rotation: rotation)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let size = rotation.logicalSize(width: 3, height: 2)
            XCTAssertEqual(image.width, size.width)
            XCTAssertEqual(image.height, size.height)
            guard image.width == size.width, image.height == size.height else { continue }
            for y in 0..<size.height {
                for x in 0..<size.width {
                    XCTAssertEqual(try pixel(image, x: x, y: y), colors[orders[rotation.rawValue][y * size.width + x]])
                }
            }
        }
    }

    func testWriteCreatesPNGAtExplicitDestination() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("player-png-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("screen.png")
        try PlayerFramePNG.write(frame(), to: file)
        let data = try Data(contentsOf: file)
        XCTAssertNotNil(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["screen.png"])
    }

    func testWriteRejectsNonFileDestinationAndReportsFilesystemErrors() throws {
        XCTAssertThrowsError(try PlayerFramePNG.write(frame(), to: XCTUnwrap(URL(string: "https://example.com/screen.png"))))
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("screen.png")
        XCTAssertThrowsError(try PlayerFramePNG.write(frame(), to: absent))
    }
}
