import AppKit
import Metal
import KestrelCore
import KestrelStream
import KestrelKeymap

/// Owns one window and one VM session. Keep this controller until onStopped fires;
/// closing the window requests cancellation, while cleanup finishes off the main thread.
@available(macOS 15, *)
@MainActor
public final class NativePlayerSessionController {
    public let player: PlayerWindowController
    public var onReady: (() -> Void)?
    public var onStopped: ((Result<Void, Error>) -> Void)?
    public var onCommandError: ((Error) -> Void)?
    public var onScreenshotSaved: ((URL) -> Void)?
    public var onEditKeymap: (() -> Void)? {
        didSet {
            if onEditKeymap == nil { player.supportedActions.remove(.keymapping) }
            else { player.supportedActions.insert(.keymapping) }
        }
    }

    public func editKeymap(_ keymap: Keymap, save: @escaping (Keymap) throws -> Void) throws {
        guard !stopping, !applyingOrientation, rotationTask == nil, replayTask == nil,
              !player.commandBusy, !player.isEditingKeymap, keymapLease == nil else {
            throw KestrelError.runtime("Stop keymapping or playback before editing controls")
        }
        let size = try keymapInputSize()
        player.showKeymapEditor(keymap, aspect: Double(size.width) / Double(size.height),
            save: save, dismissed: { [weak self] in self?.enableDirectPointer() })
    }
    /// Called synchronously before text authorization; the owner must stop its gameplay driver.
    public var onTextInputFocused: (() -> Void)?
    private var diagnosticKeyboard: PlayerKeyboardFocusCoordinator?

    /// Explicit diagnostic hook; production never enables this until guest verification passes.
    func configureDiagnosticKeyboard(observe: @escaping () async throws -> String?,
                                     send: @escaping (EmulatorKeyboardRequest) async throws -> Void) {
        diagnosticKeyboard?.close()
        diagnosticKeyboard = PlayerKeyboardFocusCoordinator(observe: observe,
            hostAllowsTyping: { [weak self] in
                guard let self else { return false }
                return !self.stopping && !self.player.isEditingKeymap && !self.applyingOrientation
                    && self.rotationTask == nil && self.replayTask == nil && !self.player.commandBusy
                    && self.keymapLease == nil && self.keymapWindowState().focused
            }, beforeTyping: { [weak self] in
                guard let self else { return false }
                self.onTextInputFocused?()
                return self.keymapLease == nil
            }, send: send, onError: { [weak self] error in self?.onCommandError?(error) })
        player.frameView.setKeyboardHandler({ [weak self] event in
            guard let self else { return false }
            do {
                guard let request = try PlayerKeyboardEvent.request(for: event) else { return false }
                return self.diagnosticKeyboard?.submit(request) ?? false
            } catch {
                self.onCommandError?(error)
                return true
            }
        }, focusLost: { [weak self] in self?.diagnosticKeyboard?.invalidate() })
    }

    func refreshDiagnosticKeyboard() async {
        await diagnosticKeyboard?.refresh()
    }

    private let commands: PlayerCommandDispatcher
    private let sdkRoot: URL
    private let serial: String
    private var touches: PlayerTouchDispatcher?
    private var keymapLease: PlayerKeymapSink?
    public var onStopping: (() -> Void)?
    private let session: EmulatorPlayerSession
    private let request: EmulatorFrameRequest
    private var task: Task<Void, Never>?
    private var replayTask: Task<Result<Void, Error>, Never>?
    private var rotationTask: Task<Void, Never>?
    private var rotationWorker: Task<PlayerDisplayOrientation, Error>?
    private var orientationObserver: Task<Void, Never>?
    private var applyingOrientation = false
    private var orientationRevision: UInt64 = 0
    public var onInputGeometryChanged: (() -> Void)?
    private var started = false
    private var stopping = false
    private var inputFailure: Error?

    public init(store: InstanceStore, index: Int, port: Int, title: String,
                width: Int, height: Int, device: MTLDevice) throws {
        request = try EmulatorFrameRequest(width: width, height: height, seconds: 30)
        sdkRoot = store.sdk.root
        serial = Ports.forInstance(index).serial
        session = EmulatorPlayerSession(store: store, index: index, port: port)
        commands = PlayerCommandDispatcher(sdk: store.sdk, serial: Ports.forInstance(index).serial)
        player = try PlayerWindowController(title: title, device: device)
        player.supportedActions = Set(PlayerWindowAction.allCases.filter { $0.keyCommand != nil }).union([.screenshot])
        player.onAction = { [weak self] in self?.perform($0) }
        player.onClose = { [weak self] in self?.stop() }
        player.onDisconnect = { [weak self] in self?.stop() }
    }

    public func start(coldBoot: Bool = false, snapshot: String? = nil) {
        guard !started, !stopping else { return }
        started = true
        player.showBootProgress("Starting Android…")
        player.showWindow(nil)
        let session = self.session
        task = Task { [self] in
            var failure: Error?
            do {
                let endpoint = try await Task.detached(priority: .userInitiated) {
                    try session.start(coldBoot: coldBoot, snapshot: snapshot)
                }.value
                try Task.checkCancellation()
                player.showBootProgress("Connecting to Android video…")
                let client = EmulatorFrameClient(endpoint: try EmulatorFrameEndpoint(host: endpoint.host, port: endpoint.port))
                let initial = try await firstFrame(client)
                try Task.checkCancellation()
                let epoch = player.beginConnection()
                let mailbox = player.frameView.mailbox
                _ = mailbox.offer(initial, stream: epoch)
                let root = sdkRoot
                let deviceSerial = serial
                let touchWidth = initial.width
                let touchHeight = initial.height
                let reportInputFailure: @Sendable (Error) -> Void = { [weak self] error in
                    Task { @MainActor in self?.inputFailed(error) }
                }
                let dispatcher = try await Task.detached(priority: .userInitiated) {
                    let sink = try DeviceSink(adb: ADB(sdk: AndroidSDK(root: root), serial: deviceSerial),
                                              width: touchWidth, height: touchHeight)
                    return PlayerTouchDispatcher(sink: sink, onError: reportInputFailure)
                }.value
                touches = dispatcher
                try Task.checkCancellation()
                let orientation = try await Task.detached(priority: .userInitiated) {
                    try PlayerRotationControl.inspect(adb: AndroidSDK(root: root).adb, serial: deviceSerial)
                }.value
                try Task.checkCancellation()
                try await applyObservedOrientation(orientation)
                enableDirectPointer()
                startOrientationObserver()
                onReady?()
                while !Task.isCancelled {
                    // Unary screenshots and each streaming RPC have independent sequence counters.
                    let currentEpoch = beginVideoRPC()
                    let began = ContinuousClock.now
                    do {
                        _ = try await client.stream(request, credential: session.token(for: .streamScreenshot)) { frame in
                            mailbox.offer(frame, stream: currentEpoch)
                        }
                    } catch EmulatorFrameConnectionError.timedOut {
                        // Renew only the expected bounded RPC deadline, not arbitrary failures.
                        guard began.duration(to: .now) >= .seconds(29) else { throw EmulatorFrameConnectionError.timedOut }
                    }
                    try Task.checkCancellation()
                    guard began.duration(to: .now) >= .seconds(29) else {
                        throw KestrelError.runtime("Video stream ended unexpectedly")
                    }
                }
            } catch is CancellationError {
            } catch { failure = error }
            beginStopping()
            if let replayTask { _ = await replayTask.value }
            if let rotationTask { await rotationTask.value }
            if let orientationObserver { await orientationObserver.value }
            orientationObserver = nil
            commands.close()
            player.frameView.setPointerHandler(nil)
            player.disconnect(message: failure == nil ? "Session closed" : "Player connection failed")
            if let touches {
                touches.close()
                await withCheckedContinuation { continuation in
                    if !touches.whenIdle({ continuation.resume() }) { continuation.resume() }
                }
                self.touches = nil
            }
            let cleanup = await Task.detached(priority: .userInitiated) {
                Result { try session.close() }
            }.value
            if failure == nil { failure = inputFailure }
            if case .failure(let error) = cleanup { failure = error }
            task = nil
            if let failure { onStopped?(.failure(failure)) }
            else { onStopped?(.success(())) }
        }
    }

    func beginVideoRPC() -> PlayerFrameMailbox.Stream {
        player.frameView.beginStream()
    }

    private func startOrientationObserver() {
        let adb = AndroidSDK(root: sdkRoot).adb
        let deviceSerial = serial
        orientationObserver = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    guard let self, !self.stopping else { return }
                    if self.rotationTask != nil || self.player.commandBusy { continue }
                    let revision = self.orientationRevision
                    let observed = try await Task.detached(priority: .utility) {
                        try PlayerRotationControl.inspect(adb: adb, serial: deviceSerial)
                    }.value
                    try Task.checkCancellation()
                    guard !self.stopping else { return }
                    guard revision == self.orientationRevision, self.rotationTask == nil,
                          !self.player.commandBusy else { continue }
                    try await self.applyObservedOrientation(observed)
                } catch is CancellationError { return }
                catch { self?.inputFailed(error); return }
            }
        }
    }

    private func applyObservedOrientation(_ orientation: PlayerDisplayOrientation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while player.frameView.screenshotFrame() == nil && ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let frame = player.frameView.screenshotFrame() else {
            throw KestrelError.runtime("No frame for observed display orientation")
        }
        let size = orientation.rotation.logicalSize(width: frame.width, height: frame.height)
        guard size.width == orientation.width, size.height == orientation.height else {
            throw KestrelError.runtime("Observed display dimensions do not match video")
        }
        guard player.frameView.displayedRotation != orientation.rotation else { return }
        applyingOrientation = true
        let wasBusy = player.commandBusy
        player.commandBusy = true
        defer {
            applyingOrientation = false
            player.commandBusy = wasBusy
            enableDirectPointer()
        }
        player.frameView.setPointerHandler(nil)
        player.dismissKeymapEditor()
        onInputGeometryChanged?()
        replayTask?.cancel()
        if let replayTask { _ = await replayTask.value }
        keymapLease?.close()
        keymapLease = nil
        if let touches {
            let drained: Bool = await withCheckedContinuation { continuation in
                if !touches.whenIdle({ continuation.resume(returning: true) }) {
                    continuation.resume(returning: false)
                }
            }
            guard drained else { throw KestrelError.runtime("Could not drain input for orientation change") }
        }
        try Task.checkCancellation()
        if stopping { return }
        player.frameView.setRotation(orientation.rotation)
        let redrawDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while player.frameView.displayedRotation != orientation.rotation && ContinuousClock.now < redrawDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard player.frameView.displayedRotation == orientation.rotation else {
            throw KestrelError.runtime("Observed orientation was not rendered")
        }
    }

    func inputFailed(_ error: Error) {
        guard !stopping else { return }
        inputFailure = error
        onCommandError?(error)
        stop()
    }

    private func enableDirectPointer() {
        guard !stopping, !player.isEditingKeymap, !applyingOrientation, rotationTask == nil, keymapLease == nil, let touches else { return }
        player.supportedActions.insert(.rotate)
        player.frameView.setPointerHandler { [weak self] events in
            if !touches.submit(events) {
                self?.inputFailed(KestrelError.runtime("Touch input stopped"))
            }
        }
    }

    public func acquireKeymapInput() throws -> TouchSink {
        guard !stopping, !player.isEditingKeymap, !applyingOrientation, rotationTask == nil, player.isConnected, let touches, keymapLease == nil else {
            throw KestrelError.runtime("Player input is unavailable or already leased")
        }
        guard let frame = player.frameView.screenshotFrame() else {
            throw KestrelError.runtime("No frame available for keymap geometry")
        }
        player.frameView.setPointerHandler(nil)
        let lease = PlayerKeymapSink(dispatcher: touches, geometry:
            (player.frameView.displayedRotation, frame.width, frame.height))
        keymapLease = lease
        player.supportedActions.remove(.rotate)
        return lease
    }

    /// Stop the keymap driver before releasing its lease. Queue ordering puts its final
    /// releases ahead of new pointer events; a closed lease rejects late driver writes.
    public func releaseKeymapInput() {
        keymapLease?.close()
        keymapLease = nil
        enableDirectPointer()
    }

    public func replay(_ recording: InputRecording, keymap: Keymap, sensitivity: Double,
                       completion: @escaping (Result<Void, Error>) -> Void) throws {
        guard replayTask == nil, let frame = player.frameView.screenshotFrame() else {
            throw KestrelError.runtime("Replay is already active or no guest frame is available")
        }
        _ = try acquireKeymapInput()
        guard let lease = keymapLease else { throw KestrelError.runtime("Missing replay input lease") }
        let size = player.frameView.displayedRotation.logicalSize(width: frame.width, height: frame.height)
        let width = size.width
        let height = size.height
        let worker = Task.detached(priority: .userInitiated) {
            let driver = Driver(engine: KeymapEngine(keymap: keymap, screenWidth: width,
                screenHeight: height, sensitivity: sensitivity), sink: lease)
            defer { driver.stop() }
            return Result { try driver.replay(recording, isCancelled: { Task.isCancelled }) }
        }
        replayTask = worker
        Task { [self] in
            let result = await worker.value
            replayTask = nil
            releaseKeymapInput()
            completion(result)
        }
    }

    public func keymapInputSize() throws -> (width: Int, height: Int) {
        guard !stopping, !applyingOrientation, rotationTask == nil, let frame = player.frameView.screenshotFrame() else {
            throw KestrelError.runtime("Player geometry is unavailable")
        }
        return player.frameView.displayedRotation.logicalSize(width: frame.width, height: frame.height)
    }

    /// Quartz screen coordinates for the actual aspect-fit guest image, not the toolbar.
    public func keymapWindowState() -> (frame: CGRect?, focused: Bool) {
        let view = player.frameView
        guard !stopping, player.isConnected, let window = player.window,
              let size = try? keymapInputSize(),
              let viewport = PlayerViewport(imageWidth: size.width, imageHeight: size.height,
                  surfaceWidth: Double(view.bounds.width), surfaceHeight: Double(view.bounds.height)),
              let primary = NSScreen.screens.first else { return (nil, false) }
        let local = NSRect(x: view.bounds.minX + viewport.x,
            y: view.isFlipped ? view.bounds.minY + viewport.y : view.bounds.maxY - viewport.y - viewport.height,
            width: viewport.width, height: viewport.height)
        let screen = window.convertToScreen(view.convert(local, to: nil))
        let quartz = CGRect(x: screen.minX, y: primary.frame.maxY - screen.maxY,
                            width: screen.width, height: screen.height)
        let focused = NSApp.isActive && window.isKeyWindow && window.attachedSheet == nil
            && window.firstResponder === view && !view.isHidden && !window.isMiniaturized
        return (quartz, focused)
    }

    private func firstFrame(_ client: EmulatorFrameClient) async throws -> PlayerFrame {
        for attempt in 0..<20 {
            try Task.checkCancellation()
            do {
                if let frame = try await client.screenshot(request, credential: session.token(for: .getScreenshot)) {
                    return frame
                }
            } catch EmulatorFrameConnectionError.rejected {
                if attempt == 19 { throw EmulatorFrameConnectionError.rejected }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw KestrelError.runtime("No initial player frame")
    }

    func rotateDisplay() {
        guard !stopping, !applyingOrientation, rotationTask == nil, !player.commandBusy, player.isConnected,
              keymapLease == nil, replayTask == nil, let touches else { return }
        player.commandBusy = true
        player.frameView.setPointerHandler(nil)
        let adb = AndroidSDK(root: sdkRoot).adb
        let deviceSerial = serial
        orientationRevision &+= 1
        rotationTask = Task { [self] in
            defer {
                rotationWorker = nil
                rotationTask = nil
                player.commandBusy = false
                enableDirectPointer()
            }
            do {
                let drained: Bool = await withCheckedContinuation { continuation in
                    if !touches.whenIdle({ continuation.resume(returning: true) }) {
                        continuation.resume(returning: false)
                    }
                }
                guard drained else { throw KestrelError.runtime("Could not drain touch input before rotation") }
                if stopping { return }
                let worker = Task.detached(priority: .userInitiated) {
                    try PlayerRotationControl.rotate(adb: adb, serial: deviceSerial,
                                                     isCancelled: { Task.isCancelled })
                }
                rotationWorker = worker
                let orientation = try await worker.value
                if stopping { return }
                guard let frame = player.frameView.screenshotFrame() else {
                    throw KestrelError.runtime("Video unavailable after rotation")
                }
                let size = orientation.rotation.logicalSize(width: frame.width, height: frame.height)
                guard size.width == orientation.width, size.height == orientation.height else {
                    throw KestrelError.runtime("Rotated display dimensions do not match video")
                }
                player.frameView.setRotation(orientation.rotation)
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while !stopping, player.frameView.displayedRotation != orientation.rotation,
                      ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard stopping || player.frameView.displayedRotation == orientation.rotation else {
                    throw KestrelError.runtime("Rotated frame was not submitted")
                }
            } catch is CancellationError {
            } catch PlayerRotationControlError.refused {
                if !stopping { onCommandError?(PlayerRotationControlError.refused) }
            } catch {
                if stopping { inputFailure = error }
                else { inputFailed(error) }
            }
        }
    }

    private func perform(_ action: PlayerWindowAction) {
        guard !stopping else { return }
        if action == .keymapping { onEditKeymap?(); return }
        if action == .rotate { rotateDisplay(); return }
        if action == .screenshot {
            guard let frame = player.frameView.screenshotFrame(), let window = player.window else { return }
            let panel = NSSavePanel()
            let rotation = player.frameView.displayedRotation
            panel.nameFieldStringValue = "Kestrel-\(UUID().uuidString).png"
            player.commandBusy = true
            panel.beginSheetModal(for: window) { [weak self] response in
                guard let self, !self.stopping else { return }
                guard response == .OK, let destination = panel.url else {
                    self.player.commandBusy = false
                    return
                }
                Task { [weak self] in
                    let result = await Task.detached(priority: .utility) {
                        Result { try PlayerFramePNG.write(frame, to: destination, rotation: rotation) }
                    }.value
                    guard let self, !self.stopping else { return }
                    self.player.commandBusy = false
                    switch result {
                    case .success: self.onScreenshotSaved?(destination)
                    case .failure(let error): self.onCommandError?(error)
                    }
                }
            }
            return
        }
        guard let command = action.keyCommand else { return }
        player.commandBusy = true
        if !commands.submit(command, completion: { [weak self] result in
            guard let self, !self.stopping else { return }
            self.player.commandBusy = false
            if case .failure(let error) = result { self.onCommandError?(error) }
        }) {
            player.commandBusy = false
            onCommandError?(KestrelError.runtime("Player command worker is unavailable"))
        }
    }

    private func beginStopping() {
        guard !stopping else { return }
        stopping = true
        diagnosticKeyboard?.close()
        diagnosticKeyboard = nil
        player.frameView.setKeyboardHandler(nil)
        replayTask?.cancel()
        rotationWorker?.cancel()
        orientationObserver?.cancel()
        onStopping?()
        keymapLease?.close()
        keymapLease = nil
    }

    public func stop() {
        guard !stopping else { return }
        beginStopping()
        commands.close()
        session.requestCancellation()
        task?.cancel()
        player.disconnect(message: "Stopping session")
    }
}
