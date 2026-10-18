import XCTest
@testable import KestrelCore

final class PlayerViewportTests: XCTestCase {
    func testLandscapeLetterboxingAndPixelMapping() throws {
        let viewport = try XCTUnwrap(PlayerViewport(imageWidth: 1280, imageHeight: 720,
                                                    surfaceWidth: 1000, surfaceHeight: 1000))
        XCTAssertEqual(viewport.x, 0)
        XCTAssertEqual(viewport.y, 218.75)
        XCTAssertEqual(viewport.width, 1000)
        XCTAssertEqual(viewport.height, 562.5)
        XCTAssertNil(viewport.pixel(x: 500, y: 100))
        XCTAssertNil(viewport.pixel(x: 500, y: 900))
        XCTAssertEqual(viewport.pixel(x: 0, y: 218.75)?.x, 0)
        XCTAssertEqual(viewport.pixel(x: 0, y: 218.75)?.y, 0)
        XCTAssertEqual(viewport.pixel(x: 500, y: 500)?.x, 640)
        XCTAssertEqual(viewport.pixel(x: 500, y: 500)?.y, 360)
        XCTAssertEqual(viewport.pixel(x: 999.999, y: 781.249)?.x, 1279)
        XCTAssertEqual(viewport.pixel(x: 999.999, y: 781.249)?.y, 719)
        XCTAssertNil(viewport.pixel(x: 1000, y: 500))
        XCTAssertNil(viewport.pixel(x: 500, y: 781.25))
    }

    func testPortraitAndScaledCoordinates() throws {
        let points = try XCTUnwrap(PlayerViewport(imageWidth: 720, imageHeight: 1280,
                                                  surfaceWidth: 1000, surfaceHeight: 500))
        let pixels = try XCTUnwrap(PlayerViewport(imageWidth: 720, imageHeight: 1280,
                                                  surfaceWidth: 2000, surfaceHeight: 1000))
        XCTAssertEqual(points.width, 281.25)
        XCTAssertEqual(points.height, 500)
        XCTAssertNil(points.pixel(x: 100, y: 250))
        let a = points.pixel(x: 500, y: 125)
        let b = pixels.pixel(x: 1000, y: 250)
        XCTAssertEqual(a?.x, 360)
        XCTAssertEqual(a?.y, 320)
        XCTAssertEqual(a?.x, b?.x)
        XCTAssertEqual(a?.y, b?.y)
    }

    func testInvalidOrNonfiniteSizesAndCoordinates() throws {
        for size in [0.0, -1, Double.nan, Double.infinity] {
            XCTAssertNil(PlayerViewport(imageWidth: 100, imageHeight: 100, surfaceWidth: size, surfaceHeight: 100))
            XCTAssertNil(PlayerViewport(imageWidth: 100, imageHeight: 100, surfaceWidth: 100, surfaceHeight: size))
        }
        XCTAssertNil(PlayerViewport(imageWidth: 0, imageHeight: 100, surfaceWidth: 100, surfaceHeight: 100))
        let v = try XCTUnwrap(PlayerViewport(imageWidth: 100, imageHeight: 100, surfaceWidth: 100, surfaceHeight: 100))
        XCTAssertNil(v.pixel(x: .nan, y: 10))
        XCTAssertNil(v.pixel(x: 10, y: .infinity))
        XCTAssertNil(v.pixel(x: -1, y: 10))
    }
}
