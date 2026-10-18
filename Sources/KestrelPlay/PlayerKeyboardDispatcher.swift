import Foundation
import KestrelStream

public enum PlayerKeyboardDispatchError: Error, Equatable {
    case overflow
}

/// One RPC at a time; focus changes discard queued text and cancel the in-flight RPC.
/// Cancellation cannot undo a key the guest has already received.
@available(macOS 15, *)
@MainActor
public final class PlayerKeyboardDispatcher {
    private let capacity: Int
    private let send: (EmulatorKeyboardRequest) async throws -> Void
    private let onError: (Error) -> Void
    private struct Pending {
        let request: EmulatorKeyboardRequest
        let isAuthorized: () -> Bool
    }
    private var pending: [Pending] = []
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var closed = false

    public init(capacity: Int = 32,
                send: @escaping (EmulatorKeyboardRequest) async throws -> Void,
                onError: @escaping (Error) -> Void) {
        precondition((1...128).contains(capacity))
        self.capacity = capacity
        self.send = send
        self.onError = onError
    }

    @discardableResult
    public func submit(_ request: EmulatorKeyboardRequest, isAuthorized: @escaping () -> Bool) -> Bool {
        guard !closed, isAuthorized() else { return false }
        let keypresses = request.individualKeypresses
        // Reserve the whole batch before enqueueing: never accept a truncated prefix.
        guard keypresses.count <= capacity - pending.count else {
            close()
            onError(PlayerKeyboardDispatchError.overflow)
            return false
        }
        pending.append(contentsOf: keypresses.map { Pending(request: $0, isAuthorized: isAuthorized) })
        startWorker()
        return true
    }

    public func invalidateFocus() {
        generation &+= 1
        pending.removeAll()
        worker?.cancel()
        // Keep the worker until its RPC returns, so a new focus cannot overlap it.
    }

    public func close() {
        closed = true
        invalidateFocus()
    }

    private func startWorker() {
        guard worker == nil, !closed, !pending.isEmpty else { return }
        let epoch = generation
        worker = Task { [self] in
            defer {
                worker = nil
                startWorker()
            }
            while !closed, epoch == generation, !Task.isCancelled, !pending.isEmpty {
                let item = pending.removeFirst()
                guard item.isAuthorized() else {
                    invalidateFocus()
                    return
                }
                do {
                    try await send(item.request)
                } catch {
                    guard !closed, epoch == generation, !Task.isCancelled else { return }
                    close()
                    onError(error)
                    return
                }
            }
        }
    }
}
