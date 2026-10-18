import Foundation

/// Complete owned RGBA8 frame. Copying detaches externally mutable transport buffers;
/// callers must still synchronize the source while this initial copy is made.
public struct PlayerFrame: Sendable {
    public static let maximumBytes = 64 * 1024 * 1024
    public static let maximumDimension = 8192

    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let sequence: UInt64
    public let timestampMicroseconds: UInt64
    public let rgba: Data
    /// Sensor-derived protocol metadata; not necessarily Android's applied display rotation.
    public let sensorRotation: PlayerRotation?

    public init(width: Int, height: Int, bytesPerRow: Int, sequence: UInt64,
                timestampMicroseconds: UInt64, rgba: Data, sensorRotation: PlayerRotation? = nil) throws {
        guard (1...Self.maximumDimension).contains(width),
              (1...Self.maximumDimension).contains(height) else {
            throw KestrelError.invalid("Player frame dimensions exceed supported bounds")
        }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (length, lengthOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !lengthOverflow, bytesPerRow >= rowBytes,
              length > 0, length <= Self.maximumBytes, rgba.count == length else {
            throw KestrelError.invalid("Invalid player frame stride or byte count")
        }
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.sequence = sequence
        self.timestampMicroseconds = timestampMicroseconds
        self.sensorRotation = sensorRotation
        self.rgba = rgba.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: length) }
    }
}

/// One pending frame, never a history queue. A renderer takes ownership of a frame and
/// retains it until its GPU work completes. Its own in-flight GPU buffers need a separate bound.
public final class PlayerFrameMailbox: @unchecked Sendable {
    public struct Stream: Hashable, Sendable {
        fileprivate let id = UUID()
        fileprivate init() {}
    }

    private let lock = NSLock()
    private var current: Stream?
    private var pending: PlayerFrame?
    private var highestSequence: UInt64?
    private var replacements: UInt64 = 0

    public init() {}

    public func beginStream() -> Stream {
        lock.lock()
        defer { lock.unlock() }
        let stream = Stream()
        current = stream
        pending = nil
        highestSequence = nil
        replacements = 0
        return stream
    }

    @discardableResult
    public func offer(_ frame: PlayerFrame, stream: Stream) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard current == stream else { return false }
        if let highestSequence, frame.sequence <= highestSequence { return false }
        if pending != nil, replacements < UInt64.max { replacements += 1 }
        highestSequence = frame.sequence
        pending = frame
        return true
    }

    public func takeLatest() -> PlayerFrame? {
        lock.lock()
        defer { lock.unlock() }
        let frame = pending
        pending = nil
        return frame
    }

    public func endStream(_ stream: Stream) {
        lock.lock()
        defer { lock.unlock() }
        guard current == stream else { return }
        pending = nil
        current = nil
        highestSequence = nil
    }

    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending == nil ? 0 : 1
    }

    public var replacedCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return replacements
    }
}
