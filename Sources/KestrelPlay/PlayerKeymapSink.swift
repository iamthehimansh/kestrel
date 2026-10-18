import Foundation
import KestrelCore
import KestrelKeymap

/// A keymap borrows the session's dispatcher exclusively while direct pointer input is off.
/// Closing this lease releases touches, not the session-owned transport.
final class PlayerKeymapSink: TouchSink, @unchecked Sendable {
    private let dispatcher: PlayerTouchDispatcher
    private let lock = NSLock()
    private var closed = false
    private var activeSlots: Set<Int> = []

    private let geometry: (rotation: PlayerRotation, width: Int, height: Int)?

    init(dispatcher: PlayerTouchDispatcher, geometry: (rotation: PlayerRotation, width: Int, height: Int)? = nil) {
        self.dispatcher = dispatcher
        self.geometry = geometry
    }

    func send(_ ops: [TouchOp]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw KestrelError.runtime("Keymap input lease is closed") }
        let physical = try ops.map { op -> TouchOp in
            guard let geometry else { return op }
            switch op {
            case .up: return op
            case .down(let slot, let x, let y), .move(let slot, let x, let y):
                guard let pixel = geometry.rotation.physicalPixel(x: x, y: y,
                    width: geometry.width, height: geometry.height) else {
                    throw KestrelError.invalid("Keymap coordinate is outside the rotated display")
                }
                if case .down = op { return .down(slot: slot, x: pixel.x, y: pixel.y) }
                return .move(slot: slot, x: pixel.x, y: pixel.y)
            }
        }
        guard dispatcher.submit(physical) else { throw KestrelError.runtime("Keymap input transport is unavailable") }
        for op in ops {
            switch op {
            case .down(let slot, _, _): activeSlots.insert(slot)
            case .up(let slot): activeSlots.remove(slot)
            case .move: break
            }
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        _ = dispatcher.submit(activeSlots.sorted().map { .up(slot: $0) })
        activeSlots.removeAll()
    }
}
