import AppKit
import Metal
import Foundation
import KestrelCore
import KestrelPlay
import KestrelStream
import KestrelKeymap

private final class Receipt: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var first: Data?
    private var changed = false
    func record(_ frame: PlayerFrame) -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        if let first { if first != frame.rgba { changed = true } }
        else { first = frame.rgba }
        return count
    }
    var result: (Int, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (count, changed)
    }
}

@available(macOS 15, *)
@MainActor
private final class PlayerProbe: NSObject, NSApplicationDelegate {
    private var player: PlayerWindowController?
    private var session: Task<Void, Never>?
    private var finished = false
    private var stage = "initializing"

    func applicationDidFinishLaunching(_ notification: Notification) {
        session = Task { await run() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func reply(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    private func run() async {
        do {
            let signer = EmulatorTokenSigner()
            try reply(["jwks": JSONSerialization.jsonObject(with: signer.publicKeySet()),
                       "policy": JSONSerialization.jsonObject(with: EmulatorTokenSigner.accessPolicy()),
                       "key_id": signer.keyID])
            // Input arrives before any window is shown. Its parent enforces a response deadline.
            guard let line = readLine(), line.utf8.count < 8192,
                  let input = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let host = input["host"] as? String, let port = input["port"] as? Int else {
                throw KestrelError.invalid("Invalid diagnostic input")
            }
            stage = "connect"
            let client = EmulatorFrameClient(endpoint: try EmulatorFrameEndpoint(host: host, port: port))
            let format = try EmulatorFrameRequest(width: 1280, height: 720, seconds: 30)
            var initial: PlayerFrame?
            for attempt in 0..<20 {
                do {
                    initial = try await client.screenshot(format, credential: signer.token(for: .getScreenshot))
                    break
                } catch EmulatorFrameConnectionError.rejected {
                    if attempt == 19 { throw EmulatorFrameConnectionError.rejected }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            guard let initial, let gpu = MTLCreateSystemDefaultDevice() else {
                throw KestrelError.runtime("No frame or Metal device")
            }
            stage = "window"
            let window = try PlayerWindowController(title: "Live video diagnostic", device: gpu)
            player = window
            guard let sdkPath = input["sdk"] as? String, let serial = input["serial"] as? String,
                  serial == "emulator-5580" else { throw KestrelError.invalid("Missing test device identity") }
            let dispatcher = PlayerCommandDispatcher(sdk: AndroidSDK(root: URL(fileURLWithPath: sdkPath)), serial: serial)
            defer { dispatcher.close() }
            var homeResult: Result<Void, Error>?
            var screenshotResult: Result<Void, Error>?
            guard let screenshotPath = input["screenshot"] as? String else {
                throw KestrelError.invalid("Missing diagnostic screenshot destination")
            }
            let screenshotURL = URL(fileURLWithPath: screenshotPath)
            window.supportedActions = Set(PlayerWindowAction.allCases.filter { $0.keyCommand != nil }).union([.screenshot])
            window.onAction = { [weak window] action in
                guard let window else { return }
                if action == .screenshot {
                    guard let frame = window.frameView.screenshotFrame() else {
                        screenshotResult = .failure(KestrelError.runtime("No guest frame available"))
                        return
                    }
                    window.commandBusy = true
                    Task { @MainActor [weak window] in
                        let result = await Task.detached(priority: .utility) {
                            Result { try PlayerFramePNG.write(frame, to: screenshotURL) }
                        }.value
                        screenshotResult = result
                        window?.commandBusy = false
                    }
                    return
                }
                guard let key = action.keyCommand else { return }
                window.commandBusy = true
                let accepted = dispatcher.submit(key) { [weak window] result in
                    window?.commandBusy = false
                    if action == .home { homeResult = result }
                    if case .failure = result { window?.disconnect(message: "Android command failed") }
                }
                if !accepted {
                    window.commandBusy = false
                    if action == .home { homeResult = .failure(KestrelError.runtime("Command worker busy")) }
                }
            }
            window.onDisconnect = { dispatcher.close() }
            window.showWindow(nil)
            guard let native = window.window else { throw KestrelError.runtime("No window") }
            native.orderFront(nil)
            let streamID = window.beginConnection()
            let mailbox = window.frameView.mailbox
            _ = mailbox.offer(initial, stream: streamID)
            let receipt = Receipt()
            let token = try signer.token(for: .streamScreenshot)
            let began = ContinuousClock.now
            var renderError = false
            window.frameView.onRenderError = { [weak window] _ in
                renderError = true
                window?.disconnect(message: "Render error")
            }
            stage = "stream"
            let streaming = Task {
                try await client.stream(format, credential: token) { frame in
                    let count = receipt.record(frame)
                    return mailbox.offer(frame, stream: streamID) && count < 600
                }
            }
            defer { streaming.cancel() }
            try await Task.sleep(for: .seconds(4))
            guard window.frameView.submittedFrames >= 30, receipt.result.1, !renderError else {
                throw KestrelError.runtime("No moving frames presented")
            }
            stage = "pointer_delivery"
            let touchSDK = AndroidSDK(root: URL(fileURLWithPath: sdkPath))
            var touchFailed = false
            let reportTouchError: (Error) -> Void = { _ in touchFailed = true }
            let touches = try await Task.detached(priority: .userInitiated) {
                let sink = try DeviceSink(adb: ADB(sdk: touchSDK, serial: serial), width: 1280, height: 720)
                return PlayerTouchDispatcher(sink: sink, onError: reportTouchError)
            }.value
            defer { touches.close() }
            var pointerEvents: [TouchOp] = []
            window.frameView.setPointerHandler { events in
                pointerEvents += events
                if !touches.submit(events) { touchFailed = true }
            }
            func drainTouches() async throws {
                var idle = false
                guard touches.whenIdle({ idle = true }) else {
                    throw KestrelError.runtime("Touch idle waiter already registered")
                }
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while !idle && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard idle, !touchFailed else { throw KestrelError.runtime("Touch dispatch failed or timed out") }
            }
            do {
                let view = window.frameView
                let center = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
                func event(_ type: NSEvent.EventType, xOffset: CGFloat = 0) throws -> NSEvent {
                    let point = NSPoint(x: center.x + xOffset, y: center.y)
                    guard let event = NSEvent.mouseEvent(with: type,
                        location: view.convert(point, to: nil), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: native.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                        throw KestrelError.runtime("Could not create diagnostic pointer event")
                    }
                    return event
                }
                view.mouseDown(with: try event(.leftMouseDown))
                guard pointerEvents == [.down(slot: 0, x: 640, y: 360)] else {
                    throw KestrelError.runtime("Native pointer did not map to guest center")
                }
                try await drainTouches()
                try await Task.sleep(for: .milliseconds(80))
                for step in 1...12 {
                    view.mouseDragged(with: try event(.leftMouseDragged, xOffset: CGFloat(step * 4)))
                    try await Task.sleep(for: .milliseconds(16))
                }
                view.mouseUp(with: try event(.leftMouseUp, xOffset: 48))
                try await drainTouches()
                guard pointerEvents.last == .up(slot: 0),
                      pointerEvents.filter({ if case .up = $0 { return true }; return false }).count == 1,
                      pointerEvents.contains(where: { if case .move = $0 { return true }; return false }) else {
                    throw KestrelError.runtime("Native drag did not preserve move/release boundaries")
                }
                view.setPointerHandler(nil)
                touches.close()
                try await drainTouches()
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                window.frameView.setPointerHandler(nil)
                touches.close()
                throw error
            }
            stage = "screenshot_action"
            guard window.perform(.screenshot) else { throw KestrelError.runtime("Screenshot action not accepted") }
            let screenshotDeadline = ContinuousClock.now.advanced(by: .seconds(5))
            while screenshotResult == nil && ContinuousClock.now < screenshotDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            guard case .success? = screenshotResult else { throw KestrelError.runtime("Screenshot action failed") }
            stage = "capture"
            try reply(["event": "capture_window", "window_id": native.windowNumber,
                       "received_frames": receipt.result.0,
                       "submitted_frames": window.frameView.submittedFrames])
            // Keep rendering while the parent captures just this window.
            try await Task.sleep(for: .seconds(3))
            stage = "home_command"
            guard window.perform(.home) else { throw KestrelError.runtime("Home action not accepted") }
            let homeDeadline = ContinuousClock.now.advanced(by: .seconds(7))
            while homeResult == nil && ContinuousClock.now < homeDeadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            guard case .success? = homeResult else { throw KestrelError.runtime("Home command failed or timed out") }
            try await Task.sleep(for: .milliseconds(500))
            stage = "cancel"
            let cancelAt = ContinuousClock.now
            streaming.cancel()
            do { _ = try await streaming.value }
            catch is CancellationError { }
            let cancelSeconds = Self.seconds(cancelAt.duration(to: .now))
            let submitted = window.frameView.submittedFrames
            let received = receipt.result
            let replaced = mailbox.replacedCount
            guard !renderError, cancelSeconds < 2, submitted >= 60, received.0 >= 60 else {
                throw KestrelError.runtime("Native playback or cancellation failed")
            }
            window.disconnect(message: "Diagnostic complete")
            guard !mailbox.offer(initial, stream: streamID) else {
                throw KestrelError.runtime("Disconnected mailbox accepted stale frame")
            }
            window.close()
            player = nil
            try reply(["status": "completed", "received_frames": received.0,
                       "submitted_frames": submitted, "changed_pixels": received.1,
                       "replaced_pending_frames": replaced, "seconds": Self.seconds(began.duration(to: .now)),
                       "cancellation_seconds": cancelSeconds, "stale_frame_rejected": true,
                       "home_command_completed": true, "screenshot_action_completed": true,
                       "pointer_down_up_forwarded": true, "pointer_drag_forwarded": true,
                       "limits": "Metal submissions are not measured scanout FPS or input-to-photon latency."])
            finish(0)
        } catch {
            var result: [String: Any] = ["status": "failed", "stage": stage,
                                         "error_type": String(describing: type(of: error))]
            if let safe = error as? EmulatorFrameConnectionError { result["safe_code"] = String(describing: safe) }
            try? reply(result)
            finish(1)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func finish(_ code: Int32) {
        guard !finished else { return }
        finished = true
        player?.close()
        player = nil
        exit(code)
    }
}

@main
struct NativePlayerProbe {
    static func main() {
        guard isatty(STDIN_FILENO) == 0, isatty(STDOUT_FILENO) == 0 else {
            fputs("Diagnostic requires controller pipes\n", stderr); exit(2)
        }
        guard #available(macOS 15, *) else { exit(2) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = PlayerProbe()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
