import AppKit
import MetalKit
import KestrelCore
import KestrelKeymap

/// Main-thread presentation surface. Producers offer owned frames through the thread-safe
/// mailbox; no per-frame main-queue dispatch is required. A host closes/hides this view when
/// a stream ends (the last drawable may remain visible until then).
public final class PlayerFrameView: MTKView, MTKViewDelegate {
    public let mailbox: PlayerFrameMailbox
    public private(set) var submittedFrames: UInt64 = 0
    public var onRenderError: ((Error) -> Void)?
    private let renderer: PlayerFrameRenderer
    private var stream: PlayerFrameMailbox.Stream?
    private var latest: PlayerFrame?
    private var displayed: PlayerFrame?
    private var rotation: PlayerRotation = .natural
    public private(set) var displayedRotation: PlayerRotation = .natural

    public func setRotation(_ rotation: PlayerRotation) {
        precondition(Thread.isMainThread)
        guard self.rotation != rotation else { return }
        cancelPointer()
        self.rotation = rotation
        needsFrame = true
    }
    private var needsFrame = false
    private var pointer = PlayerPointer()
    private var pointerHandler: (([TouchOp]) -> Void)?
    private var keyboardHandler: ((NSEvent) -> Bool)?
    private var keyboardFocusLost: (() -> Void)?

    /// Opt-in only: the host must independently authorize the current Android editor.
    public func setKeyboardHandler(_ handler: ((NSEvent) -> Bool)?, focusLost: (() -> Void)? = nil) {
        precondition(Thread.isMainThread)
        keyboardFocusLost?()
        keyboardHandler = handler
        keyboardFocusLost = focusLost
    }

    public override func keyDown(with event: NSEvent) {
        guard stream != nil, displayed != nil, !isHiddenOrHasHiddenAncestor,
              NSApp.isActive, let window, window.isKeyWindow, window.attachedSheet == nil,
              window.firstResponder === self,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let keyboardHandler else {
            super.keyDown(with: event)
            return
        }
        if !keyboardHandler(event) { super.keyDown(with: event) }
    }

    @objc private func invalidateInputFocus() {
        cancelPointer()
        keyboardFocusLost?()
    }

    public init(device: MTLDevice, mailbox: PlayerFrameMailbox = PlayerFrameMailbox()) throws {
        precondition(Thread.isMainThread)
        self.mailbox = mailbox
        renderer = try PlayerFrameRenderer(device: device)
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        autoResizeDrawable = true
        enableSetNeedsDisplay = false
        isPaused = true
        preferredFramesPerSecond = 60
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("Use init(device:mailbox:)") }

    /// Handler must forward events promptly to an exclusively owned input slot. Release
    /// is delivered to the previous handler before replacement, including replacement by nil.
    public func setPointerHandler(_ handler: (([TouchOp]) -> Void)?) {
        precondition(Thread.isMainThread)
        emitPointer(pointer.cancel())
        pointerHandler = handler
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: PlayerCursor.gold)
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func resignFirstResponder() -> Bool {
        invalidateInputFocus()
        return super.resignFirstResponder()
    }

    @objc private func cancelPointer() {
        precondition(Thread.isMainThread)
        emitPointer(pointer.cancel())
    }

    private func emitPointer(_ events: [TouchOp]) {
        let physical = events.compactMap { event -> TouchOp? in
            switch event {
            case .up: return event
            case .down(let slot, let x, let y), .move(let slot, let x, let y):
                guard let displayed, let pixel = displayedRotation.physicalPixel(
                    x: x, y: y, width: displayed.width, height: displayed.height) else { return nil }
                if case .down = event { return .down(slot: slot, x: pixel.x, y: pixel.y) }
                return .move(slot: slot, x: pixel.x, y: pixel.y)
            }
        }
        if !physical.isEmpty { pointerHandler?(physical) }
    }

    private func refreshPointerViewport() {
        let viewport = displayed.flatMap { frame -> PlayerViewport? in
            guard rotation == displayedRotation else { return nil }
            let size = displayedRotation.logicalSize(width: frame.width, height: frame.height)
            return PlayerViewport(imageWidth: size.width, imageHeight: size.height,
                                  surfaceWidth: Double(bounds.width), surfaceHeight: Double(bounds.height))
        }
        emitPointer(pointer.updateViewport(viewport))
    }

    private func pointerPoint(_ event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return NSPoint(x: point.x - bounds.minX,
                       y: isFlipped ? point.y - bounds.minY : bounds.maxY - point.y)
    }

    public override func mouseDown(with event: NSEvent) {
        guard stream != nil, displayed != nil, pointerHandler != nil else { return }
        window?.makeFirstResponder(self)
        refreshPointerViewport()
        let point = pointerPoint(event)
        emitPointer(pointer.begin(x: point.x, y: point.y))
    }

    public override func mouseDragged(with event: NSEvent) {
        refreshPointerViewport()
        let point = pointerPoint(event)
        emitPointer(pointer.move(x: point.x, y: point.y))
    }

    public override func mouseUp(with event: NSEvent) { emitPointer(pointer.end()) }

    public override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize { cancelPointer() }
        super.setFrameSize(newSize)
        needsFrame = true
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        invalidateInputFocus()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil)
        super.viewWillMove(toWindow: newWindow)
    }

    @discardableResult
    public func beginStream() -> PlayerFrameMailbox.Stream {
        precondition(Thread.isMainThread)
        stopStream()
        let next = mailbox.beginStream()
        stream = next
        submittedFrames = 0
        isPaused = window == nil
        return next
    }

    public func stopStream() {
        precondition(Thread.isMainThread)
        keyboardFocusLost?()
        isPaused = true
        emitPointer(pointer.updateViewport(nil))
        if let stream { mailbox.endStream(stream) }
        stream = nil
        latest = nil
        displayed = nil
        needsFrame = false
        releaseDrawables()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        precondition(Thread.isMainThread)
        isPaused = window == nil || stream == nil
        if let window {
            needsFrame = true
            NotificationCenter.default.addObserver(self, selector: #selector(invalidateInputFocus),
                name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(invalidateInputFocus),
                name: NSApplication.didResignActiveNotification, object: nil)
        }
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        precondition(Thread.isMainThread)
        cancelPointer()
        needsFrame = true
    }

    public func draw(in view: MTKView) {
        precondition(Thread.isMainThread)
        guard view === self, let stream, window != nil, !isPaused else { return }
        // Avoid asking Core Animation for a drawable on idle ticks. Acquire it before
        // taking the mailbox frame, so detached/unavailable surfaces cannot drain input.
        guard needsFrame || mailbox.pendingCount > 0, let drawable = currentDrawable else { return }
        if let newest = mailbox.takeLatest() {
            latest = newest
            needsFrame = true
        }
        guard let frame = latest else { return }
        do {
            let accepted = try renderer.render(frame, into: drawable.texture, drawable: drawable, rotation: rotation) { [weak self] error in
                guard let error else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.stream == stream else { return }
                    self.stopStream()
                    self.onRenderError?(error)
                }
            }
            if accepted {
                displayed = frame
                displayedRotation = rotation
                refreshPointerViewport()
                needsFrame = false
                if submittedFrames < UInt64.max { submittedFrames += 1 }
            }
            // If GPU slots are occupied, retain only this latest candidate. A newer mailbox
            // frame replaces it on the next tick rather than building a submission queue.
        } catch {
            stopStream()
            onRenderError?(error)
        }
    }

    /// Retains the last submitted guest frame for off-main encoding. This is not a
    /// desktop capture or a guarantee that the monitor has scanned out this frame yet.
    public func screenshotFrame() -> PlayerFrame? {
        precondition(Thread.isMainThread)
        return displayed
    }

    /// Converts a view-local AppKit point to a top-left-origin guest pixel, ignoring margins.
    /// Geometry follows the most recently submitted frame, not an unpresented newer frame.
    public func pixel(at point: NSPoint) -> PlayerViewport.Pixel? {
        precondition(Thread.isMainThread)
        guard let displayed, rotation == displayedRotation else { return nil }
        let size = displayedRotation.logicalSize(width: displayed.width, height: displayed.height)
        guard let viewport = PlayerViewport(imageWidth: size.width, imageHeight: size.height,
                  surfaceWidth: Double(bounds.width), surfaceHeight: Double(bounds.height)) else { return nil }
        let y = isFlipped ? point.y - bounds.minY : bounds.maxY - point.y
        guard let logical = viewport.pixel(x: Double(point.x - bounds.minX), y: Double(y)) else { return nil }
        return displayedRotation.physicalPixel(x: logical.x, y: logical.y,
                                               width: displayed.width, height: displayed.height)
    }
}
