import Foundation
import KestrelCore
import KestrelStream

/// The observer supplies a validated editor identity, never field contents.
/// Host focus invalidation must be delivered even if focus returns before a query completes.
@available(macOS 15, *)
@MainActor
final class PlayerKeyboardFocusCoordinator {
    private let observe: () async throws -> String?
    private let hostAllowsTyping: () -> Bool
    private let beforeTyping: () -> Bool
    private let clock: () -> TimeInterval
    private let lifetime: TimeInterval
    private let dispatcher: PlayerKeyboardDispatcher
    private var focus: PlayerTextFocus
    private var revision: UInt64 = 0
    private var observing = false
    private var closed = false
    private var currentEditor: String?

    init(lifetime: TimeInterval = 0.5,
         observe: @escaping () async throws -> String?,
         hostAllowsTyping: @escaping () -> Bool,
         beforeTyping: @escaping () -> Bool,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         send: @escaping (EmulatorKeyboardRequest) async throws -> Void,
         onError: @escaping (Error) -> Void) {
        self.lifetime = lifetime
        focus = PlayerTextFocus(lifetime: lifetime)
        self.observe = observe
        self.hostAllowsTyping = hostAllowsTyping
        self.beforeTyping = beforeTyping
        self.clock = clock
        dispatcher = PlayerKeyboardDispatcher(send: send, onError: onError)
    }

    func invalidate() {
        revision &+= 1
        currentEditor = nil
        focus.invalidate()
        dispatcher.invalidateFocus()
    }

    func close() {
        closed = true
        invalidate()
        dispatcher.close()
    }

    func refresh() async {
        guard !closed, !observing else { return }
        guard hostAllowsTyping() else { invalidate(); return }
        observing = true
        defer { observing = false }
        let epoch = revision
        let began = clock()
        do {
            let editor = try await observe()
            guard !closed, epoch == revision else { return }
            let now = clock()
            guard !Task.isCancelled, hostAllowsTyping(), began.isFinite, now.isFinite,
                  began >= 0, now >= began, now - began <= lifetime else {
                invalidate()
                return
            }
            guard let editor, !editor.isEmpty, editor.utf8.count <= 256 else {
                invalidate()
                return
            }
            if currentEditor != editor || focus.permit(at: now) == nil {
                invalidate()
                let preparationEpoch = revision
                guard beforeTyping(), !closed, revision == preparationEpoch, hostAllowsTyping() else { return }
                currentEditor = editor
            }
            focus.updateHost(focused: true, overlayOpen: false)
            // Freshness starts before the observation, not when a slow query finishes.
            focus.observe(editorID: editor, at: began)
        } catch {
            if !closed, epoch == revision { invalidate() }
        }
    }

    @discardableResult
    func submit(_ request: EmulatorKeyboardRequest) -> Bool {
        guard !closed, hostAllowsTyping(), let permit = focus.permit(at: clock()) else {
            invalidate()
            return false
        }
        let epoch = revision
        return dispatcher.submit(request, isAuthorized: { [weak self] in
            guard let self else { return false }
            return !self.closed && self.revision == epoch && self.hostAllowsTyping()
                && self.focus.permits(permit, at: self.clock())
        })
    }
}
