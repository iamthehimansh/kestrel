import Foundation

/// Authorization state only; never stores field contents. A queued key carries the
/// revision from acceptance and must be checked again immediately before transmission.
public struct PlayerTextFocus {
    private let lifetime: TimeInterval
    private var observedAt: TimeInterval?
    private var editorID: String?
    private var hostFocused = false
    private var overlayOpen = false
    private var revision: UInt64 = 0

    public init(lifetime: TimeInterval = 0.5) {
        precondition(lifetime.isFinite && lifetime > 0 && lifetime <= 2)
        self.lifetime = lifetime
    }

    public mutating func updateHost(focused: Bool, overlayOpen: Bool) {
        guard focused != hostFocused || overlayOpen != self.overlayOpen else { return }
        hostFocused = focused
        self.overlayOpen = overlayOpen
        invalidate()
    }

    public mutating func observe(editorID: String?, at time: TimeInterval) {
        guard time.isFinite, time >= 0, observedAt.map({ time >= $0 }) ?? true else {
            invalidate()
            return
        }
        let valid = editorID.flatMap { !$0.isEmpty && $0.utf8.count <= 256 ? $0 : nil }
        if valid != self.editorID || (observedAt.map({ time - $0 > lifetime }) ?? true) {
            revision &+= 1
        }
        self.editorID = valid
        observedAt = time
    }

    public mutating func invalidate() {
        revision &+= 1
        editorID = nil
        observedAt = nil
    }

    public func permit(at time: TimeInterval) -> UInt64? {
        guard hostFocused, !overlayOpen, editorID != nil,
              let observedAt, time.isFinite, time >= observedAt, time - observedAt <= lifetime else { return nil }
        return revision
    }

    public func permits(_ acceptedRevision: UInt64, at time: TimeInterval) -> Bool {
        permit(at: time) == acceptedRevision
    }
}
