import KestrelCore
import KestrelKeymap

/// Single direct-touch gesture in top-left view coordinates. The host must grant exclusive
/// ownership of slot zero and forward cancellation before disconnecting its touch sink.
public struct PlayerPointer {
    private var viewport: PlayerViewport?
    private var held: PlayerViewport.Pixel?

    public init() {}

    public mutating func updateViewport(_ next: PlayerViewport?) -> [TouchOp] {
        guard viewport != next else { return [] }
        let release = cancel()
        viewport = next
        return release
    }

    public mutating func begin(x: Double, y: Double) -> [TouchOp] {
        var events = cancel()
        guard let pixel = viewport?.pixel(x: x, y: y) else { return events }
        held = pixel
        events.append(.down(slot: 0, x: pixel.x, y: pixel.y))
        return events
    }

    public mutating func move(x: Double, y: Double) -> [TouchOp] {
        guard let previous = held else { return [] }
        guard let pixel = viewport?.pixel(x: x, y: y) else { return cancel() }
        guard pixel != previous else { return [] }
        held = pixel
        return [.move(slot: 0, x: pixel.x, y: pixel.y)]
    }

    public mutating func end() -> [TouchOp] { cancel() }

    public mutating func cancel() -> [TouchOp] {
        guard held != nil else { return [] }
        held = nil
        return [.up(slot: 0)]
    }
}
