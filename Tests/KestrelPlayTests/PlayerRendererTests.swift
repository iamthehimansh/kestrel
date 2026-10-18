import Foundation
import Metal
import XCTest
import KestrelCore
@testable import KestrelPlay

final class PlayerRendererTests: XCTestCase {
    private func device() throws -> MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice(), "These rendering tests require a real Metal GPU")
    }

    private func target(_ device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func frame() throws -> PlayerFrame {
        // Top row red/green, bottom row blue/white, with non-pixel padding per row.
        let rgba: [UInt8] = [255,0,0,255, 0,255,0,255, 19,19,19,19,
                            0,0,255,255, 255,255,255,255, 29,29,29,29]
        return try PlayerFrame(width: 2, height: 2, bytesPerRow: 12, sequence: 1,
                               timestampMicroseconds: 0, rgba: Data(rgba))
    }

    private func pixel(_ texture: MTLTexture, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: 4,
                             from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return bytes
    }

    func testMetalPreservesColorOrderOrientationStrideAndLetterbox() throws {
        let gpu = try device()
        let renderer = try PlayerFrameRenderer(device: gpu)
        let output = try target(gpu, width: 8, height: 4)
        let rendered = expectation(description: "GPU render completed")
        XCTAssertTrue(try renderer.render(try frame(), into: output) { error in
            XCTAssertNil(error)
            rendered.fulfill()
        })
        wait(for: [rendered], timeout: 5)
        XCTAssertEqual(pixel(output, x: 0, y: 1), [0,0,0,255], "Left letterbox is opaque black")
        XCTAssertEqual(pixel(output, x: 7, y: 2), [0,0,0,255], "Right letterbox is opaque black")
        XCTAssertEqual(pixel(output, x: 2, y: 0), [0,0,255,255], "Top-left red in BGRA target")
        XCTAssertEqual(pixel(output, x: 5, y: 0), [0,255,0,255], "Top-right green")
        XCTAssertEqual(pixel(output, x: 2, y: 3), [255,0,0,255], "Bottom-left blue")
        XCTAssertEqual(pixel(output, x: 5, y: 3), [255,255,255,255], "Bottom-right white")
    }

    func testMetalRotationMatchesUprightPixelOrderForAllOrientations() throws {
        let gpu = try device()
        let renderer = try PlayerFrameRenderer(device: gpu)
        let colors: [[UInt8]] = [[255,0,0,255], [0,255,0,255], [0,0,255,255],
                                  [255,255,0,255], [255,0,255,255], [0,255,255,255]]
        let source = try PlayerFrame(width: 3, height: 2, bytesPerRow: 12, sequence: 1,
                                     timestampMicroseconds: 0, rgba: Data(colors.flatMap { $0 }))
        let orders = [[0,1,2,3,4,5], [2,5,1,4,0,3], [5,4,3,2,1,0], [3,0,4,1,5,2]]
        for rotation in PlayerRotation.allCases {
            let size = rotation.logicalSize(width: 3, height: 2)
            let output = try target(gpu, width: size.width, height: size.height)
            let done = expectation(description: "GPU orientation \(rotation.rawValue)")
            XCTAssertTrue(try renderer.render(source, into: output, rotation: rotation) { error in
                XCTAssertNil(error)
                done.fulfill()
            })
            wait(for: [done], timeout: 5)
            for y in 0..<size.height {
                for x in 0..<size.width {
                    let rgba = colors[orders[rotation.rawValue][y * size.width + x]]
                    XCTAssertEqual(pixel(output, x: x, y: y), [rgba[2], rgba[1], rgba[0], rgba[3]])
                }
            }
        }
    }

    func testGPUBackpressureRejectsExtraFramesUntilCompletion() throws {
        let gpu = try device()
        let queue = try XCTUnwrap(gpu.makeCommandQueue())
        let gate = try XCTUnwrap(gpu.makeSharedEvent())
        let blocker = try XCTUnwrap(queue.makeCommandBuffer())
        blocker.encodeWaitForEvent(gate, value: 1)
        blocker.commit()
        defer { gate.signaledValue = 1 }
        let renderer = try PlayerFrameRenderer(device: gpu, commandQueue: queue, maxInFlight: 2)
        let output1 = try target(gpu, width: 4, height: 4)
        let output2 = try target(gpu, width: 4, height: 4)
        let done = expectation(description: "Both queued frames complete")
        done.expectedFulfillmentCount = 2
        for output in [output1, output2] {
            XCTAssertTrue(try renderer.render(try frame(), into: output) { error in
                XCTAssertNil(error)
                done.fulfill()
            })
        }
        XCTAssertFalse(try renderer.render(try frame(), into: output1) { _ in
            XCTFail("Rejected frame must not invoke completion")
        })
        gate.signaledValue = 1
        wait(for: [done], timeout: 5)
        let resumed = expectation(description: "Slot released after GPU completion")
        XCTAssertTrue(try renderer.render(try frame(), into: output1) { error in
            XCTAssertNil(error)
            resumed.fulfill()
        })
        wait(for: [resumed], timeout: 5)
    }

    func testInvalidTargetDoesNotConsumeAnInFlightSlot() throws {
        let gpu = try device()
        let renderer = try PlayerFrameRenderer(device: gpu, maxInFlight: 1)
        let bad = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: 4, height: 4, mipmapped: false)
        bad.usage = [.renderTarget]
        let wrongFormat = try XCTUnwrap(gpu.makeTexture(descriptor: bad))
        XCTAssertThrowsError(try renderer.render(try frame(), into: wrongFormat) { _ in
            XCTFail("Invalid target must not be submitted")
        })
        let done = expectation(description: "Valid frame after error")
        XCTAssertTrue(try renderer.render(try frame(), into: target(gpu, width: 4, height: 4)) { error in
            XCTAssertNil(error)
            done.fulfill()
        })
        wait(for: [done], timeout: 5)
    }
}
