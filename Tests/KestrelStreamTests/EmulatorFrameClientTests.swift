import Foundation
import XCTest
import KestrelCore
@testable import KestrelStream

@available(macOS 15, *)
final class EmulatorFrameClientTests: XCTestCase {
    func testEndpointAcceptsOnlyLiteralLoopbackAndUnprivilegedPort() throws {
        for host in ["127.0.0.1", "::1"] {
            let endpoint = try EmulatorFrameEndpoint(host: host, port: 8556)
            XCTAssertEqual(endpoint.host, host)
            XCTAssertEqual(endpoint.port, 8556)
        }
        for host in ["localhost", "0.0.0.0", "192.168.1.2", "example.com", "127.0.0.1.evil", "[::1]", ""] {
            XCTAssertThrowsError(try EmulatorFrameEndpoint(host: host, port: 8556))
        }
        for port in [-1, 0, 80, 65536] {
            XCTAssertThrowsError(try EmulatorFrameEndpoint(host: "127.0.0.1", port: port))
        }
    }

    func testRequestDimensionsAndDeadlineAreBounded() throws {
        let request = try EmulatorFrameRequest(width: 1280, height: 720, seconds: 30)
        XCTAssertEqual(request.maximumPixelBytes, 1280 * 720 * 4)
        XCTAssertEqual(request.options.maxRequestMessageBytes, request.maximumPixelBytes + 64 * 1024,
                       "Pinned NIO transport applies this bound to incoming frames too")
        XCTAssertEqual(request.options.maxResponseMessageBytes, request.maximumPixelBytes + 64 * 1024)
        XCTAssertEqual(request.message.format, .rgba8888)
        XCTAssertEqual(request.message.display, 0)
        for size in [(0, 720), (-1, 720), (8193, 1), (8192, 8192)] {
            XCTAssertThrowsError(try EmulatorFrameRequest(width: size.0, height: size.1, seconds: 30))
        }
        for duration in [0, -1, 61] {
            XCTAssertThrowsError(try EmulatorFrameRequest(width: 2, height: 2, seconds: duration))
        }
    }

    private func message(_ sequence: UInt32 = 1) -> Android_Emulation_Control_Image {
        var image = Android_Emulation_Control_Image()
        image.format.format = .rgba8888
        image.format.width = 2
        image.format.height = 2
        image.image = Data(repeating: 23, count: 16)
        image.seq = sequence
        image.timestampUs = 1234
        return image
    }

    func testDecodedFrameOwnsCorrectPixelDataAndRejectsSequenceRollback() throws {
        let request = try EmulatorFrameRequest(width: 2, height: 2, seconds: 5)
        var decoder = EmulatorFrameDecoder(request: request)
        let frame = try XCTUnwrap(decoder.decode(message()))
        XCTAssertEqual(frame.width, 2)
        XCTAssertEqual(frame.rgba, Data(repeating: 23, count: 16))
        XCTAssertEqual(frame.sequence, 1)
        XCTAssertEqual(frame.timestampMicroseconds, 1234)
        XCTAssertThrowsError(try decoder.decode(message()))
        XCTAssertThrowsError(try decoder.decode(message(0)))
        XCTAssertEqual(try decoder.decode(message(2))?.sequence, 2)
    }

    func testSensorRotationMetadataIsPreservedWithoutRotatingPixels() throws {
        var decoder = EmulatorFrameDecoder(request: try EmulatorFrameRequest(width: 2, height: 2, seconds: 5))
        XCTAssertNil(try decoder.decode(message(1))?.sensorRotation)
        for raw in 0...3 {
            var image = message(UInt32(raw + 2))
            image.format.rotation.rotation = .init(rawValue: raw)!
            let frame = try XCTUnwrap(decoder.decode(image))
            XCTAssertEqual(frame.sensorRotation?.rawValue, raw)
            XCTAssertEqual(frame.rgba, image.image)
        }
    }

    func testNoFrameYetIsNotRenderedAndDoesNotAdvanceSequence() throws {
        var decoder = EmulatorFrameDecoder(request: try EmulatorFrameRequest(width: 2, height: 2, seconds: 5))
        var empty = Android_Emulation_Control_Image()
        empty.format.format = .rgba8888
        empty.seq = 99
        XCTAssertNil(try decoder.decode(empty))
        XCTAssertNotNil(try decoder.decode(message()))
    }

    func testRejectsBadFormatMissingMetadataAndOutOfBoundsPayload() throws {
        let request = try EmulatorFrameRequest(width: 2, height: 2, seconds: 5)
        var malformed = [Android_Emulation_Control_Image]()
        var png = message(); png.format.format = .png; malformed.append(png)
        var rgb = message(); rgb.format.format = .rgb888; malformed.append(rgb)
        var missing = message(); missing.clearFormat(); malformed.append(missing)
        var wrongLength = message(); wrongLength.image = Data(count: 15); malformed.append(wrongLength)
        var tooWide = message(); tooWide.format.width = 3; tooWide.image = Data(count: 24); malformed.append(tooWide)
        var zeroWidth = message(); zeroWidth.format.width = 0; malformed.append(zeroWidth)
        var alternateDisplay = message(); alternateDisplay.format.display = 1; malformed.append(alternateDisplay)
        for image in malformed {
            var decoder = EmulatorFrameDecoder(request: request)
            XCTAssertThrowsError(try decoder.decode(image))
            XCTAssertNotNil(try decoder.decode(message()), "Malformed data must not advance sequence")
        }
    }
}
