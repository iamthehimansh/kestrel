import Foundation
import KestrelKeymap

public enum PlayerTouchDispatchError: Error, Equatable {
    case overflow
}

/// Exclusive sink owner. Input never waits for pipe I/O on the producer thread. A bounded
/// pending batch coalesces only adjacent moves for the same slot; gesture boundaries survive.
/// The sink must bound its own send/close calls. Closing the sink must release guest touches.
public final class PlayerTouchDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "kestrel.player.touch", qos: .userInteractive)
    private let sink: TouchSink
    private let capacity: Int
    private let onError: ((Error) -> Void)?
    private var pending: [TouchOp] = []
    private var active = false
    private var closed = false
    private var sinkClosed = false
    private var failure: Error?
    private var idleCallback: (() -> Void)?
    private var idleDeliveryScheduled = false

    public init(sink: TouchSink, capacity: Int = 64, onError: ((Error) -> Void)? = nil) {
        precondition((1...1024).contains(capacity))
        self.sink = sink
        self.capacity = capacity
        self.onError = onError
    }

    @discardableResult
    public func submit(_ events: [TouchOp]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        // Bound producer-side work too, not merely the resulting coalesced queue.
        guard events.count <= capacity else {
            failLocked(PlayerTouchDispatchError.overflow)
            scheduleLocked()
            return false
        }
        for event in events {
            if case .move(let slot, _, _) = event,
               let last = pending.last, case .move(let previousSlot, _, _) = last,
               slot == previousSlot {
                pending[pending.count - 1] = event
            } else {
                guard pending.count < capacity else {
                    failLocked(PlayerTouchDispatchError.overflow)
                    scheduleLocked()
                    return false
                }
                pending.append(event)
            }
        }
        if !pending.isEmpty { scheduleLocked() }
        return true
    }

    /// Registers one idle notification, delivered on main after accepted writes finish or
    /// the sink closes. False means a waiter is already registered; no callback queue grows.
    @discardableResult
    public func whenIdle(_ completion: @escaping () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard idleCallback == nil else { return false }
        idleCallback = completion
        scheduleIdleLocked()
        return true
    }

    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        pending.removeAll()
        scheduleLocked()
    }

    private func failLocked(_ error: Error) {
        if failure == nil { failure = error }
        closed = true
        pending.removeAll()
    }

    private func scheduleLocked() {
        guard !active else { return }
        active = true
        worker.async { [self] in drain() }
    }

    // Keep the waiter registered until the main queue observes idle. New work arriving
    // before delivery defers it until the next drain, without adding another queued callback.
    private func scheduleIdleLocked() {
        guard idleCallback != nil, !idleDeliveryScheduled, !active, pending.isEmpty else { return }
        idleDeliveryScheduled = true
        DispatchQueue.main.async { [self] in
            lock.lock()
            idleDeliveryScheduled = false
            guard !active, pending.isEmpty else { lock.unlock(); return }
            let callback = idleCallback
            idleCallback = nil
            lock.unlock()
            callback?()
        }
    }

    private func drain() {
        while true {
            lock.lock()
            if closed {
                let shouldClose = !sinkClosed
                sinkClosed = true
                let error = failure
                failure = nil
                lock.unlock()
                if shouldClose { sink.close() }
                lock.lock()
                active = false
                if let error, let onError { DispatchQueue.main.async { onError(error) } }
                scheduleIdleLocked()
                lock.unlock()
                return
            }
            guard !pending.isEmpty else {
                active = false
                scheduleIdleLocked()
                lock.unlock()
                return
            }
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            lock.unlock()
            do { try sink.send(batch) }
            catch {
                lock.lock()
                failLocked(error)
                lock.unlock()
            }
        }
    }
}
