import Foundation

/// Aspect-fit image rectangle in top-left-origin surface coordinates. Use the same surface
/// units for both the rectangle and incoming points (view points or drawable pixels).
public struct PlayerViewport: Equatable, Sendable {
    public struct Pixel: Equatable, Sendable {
        public let x: Int
        public let y: Int
    }

    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    private let imageWidth: Int
    private let imageHeight: Int

    public init?(imageWidth: Int, imageHeight: Int, surfaceWidth: Double, surfaceHeight: Double) {
        guard (1...PlayerFrame.maximumDimension).contains(imageWidth),
              (1...PlayerFrame.maximumDimension).contains(imageHeight),
              surfaceWidth.isFinite, surfaceHeight.isFinite,
              surfaceWidth > 0, surfaceHeight > 0 else { return nil }
        let scale = min(surfaceWidth / Double(imageWidth), surfaceHeight / Double(imageHeight))
        let width = Double(imageWidth) * scale
        let height = Double(imageHeight) * scale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        self.x = (surfaceWidth - width) / 2
        self.y = (surfaceHeight - height) / 2
        self.width = width
        self.height = height
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
    }

    public func pixel(x pointX: Double, y pointY: Double) -> Pixel? {
        guard pointX.isFinite, pointY.isFinite,
              pointX >= x, pointY >= y, pointX < x + width, pointY < y + height else { return nil }
        let px = min(imageWidth - 1, Int((pointX - x) / width * Double(imageWidth)))
        let py = min(imageHeight - 1, Int((pointY - y) / height * Double(imageHeight)))
        return Pixel(x: px, y: py)
    }
}
