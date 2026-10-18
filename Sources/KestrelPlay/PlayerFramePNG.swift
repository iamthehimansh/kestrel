import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import KestrelCore

/// Encodes only the guest frame supplied by the caller, never desktop or window contents.
/// PNG encoding and file writes should run off the main/presentation thread.
public enum PlayerFramePNG {
    public static func encode(_ frame: PlayerFrame, rotation: PlayerRotation = .natural) throws -> Data {
        let size = rotation.logicalSize(width: frame.width, height: frame.height)
        var pixels = frame.rgba
        var stride = frame.bytesPerRow
        if rotation != .natural {
            stride = size.width * 4
            pixels = Data(count: stride * size.height)
            pixels.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                frame.rgba.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                    for y in 0..<size.height {
                        for x in 0..<size.width {
                            // Coordinates are bounded by the validated frame and logical size.
                            let physical = rotation.physicalPixel(x: x, y: y, width: frame.width, height: frame.height)!
                            let inputOffset = physical.y * frame.bytesPerRow + physical.x * 4
                            let outputOffset = y * stride + x * 4
                            output.baseAddress!.advanced(by: outputOffset).copyMemory(
                                from: source.baseAddress!.advanced(by: inputOffset), byteCount: 4)
                        }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: size.width, height: size.height,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
                      .union(.byteOrder32Big),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw KestrelError.runtime("Could not construct guest screenshot")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw KestrelError.runtime("Could not create PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw KestrelError.runtime("Guest screenshot encoding failed")
        }
        return data as Data
    }

    public static func write(_ frame: PlayerFrame, to destination: URL, rotation: PlayerRotation = .natural) throws {
        guard destination.isFileURL else {
            throw KestrelError.invalid("Screenshot destination must be a local file")
        }
        try encode(frame, rotation: rotation).write(to: destination, options: .atomic)
    }
}
