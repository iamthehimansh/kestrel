import Foundation

/// Android display orientation relative to the unrotated emulator framebuffer.
/// Orientation 1 presents the framebuffer 90 degrees counterclockwise.
public enum PlayerRotation: Int, CaseIterable, Sendable {
    case natural = 0, quarter = 1, half = 2, threeQuarter = 3

    public var swapsAxes: Bool { rawValue % 2 == 1 }

    public func logicalSize(width: Int, height: Int) -> (width: Int, height: Int) {
        swapsAxes ? (height, width) : (width, height)
    }

    /// Maps an upright displayed pixel back into the physical touchscreen's native axes.
    public func physicalPixel(x: Int, y: Int, width: Int, height: Int) -> PlayerViewport.Pixel? {
        guard width > 0, height > 0 else { return nil }
        let size = logicalSize(width: width, height: height)
        guard x >= 0, y >= 0, x < size.width, y < size.height else { return nil }
        switch self {
        case .natural: return .init(x: x, y: y)
        case .quarter: return .init(x: width - 1 - y, y: x)
        case .half: return .init(x: width - 1 - x, y: height - 1 - y)
        case .threeQuarter: return .init(x: y, y: height - 1 - x)
        }
    }
}
