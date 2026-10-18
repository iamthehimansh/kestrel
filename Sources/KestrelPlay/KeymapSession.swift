import AppKit
import ApplicationServices
import KestrelCore
import KestrelKeymap

/// Key mapping for one running instance, started and stopped from inside an app (the CLI's
/// `play` runs its own loop instead). Main thread only.
public final class KeymapSession {
    public let instanceIndex: Int
    public let keymap: Keymap
    private let driver: Driver
    private let controller: PlayController
    private let recorder: InputRecorder?
    private var stopped = false

    /// Whether this process may read the keyboard globally. Pass `prompt` to show the
    /// system dialog that sends the user to System Settings.
    public static func hasAccessibility(prompt: Bool) -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary)
    }

    /// Pushes touchd, opens the touch channel and starts listening. Throws if the instance
    /// is not running, touch injection cannot start, or the keyboard cannot be read.
    public init(instance: Instance, store: InstanceStore, keymap: Keymap, record: Bool = false,
                sink suppliedSink: TouchSink? = nil,
                inputSize: (width: Int, height: Int)? = nil,
                windowProvider: (() -> (frame: CGRect?, focused: Bool))? = nil,
                hintParentWindow: NSWindow? = nil,
                onStatus: @escaping (String) -> Void) throws {
        guard Launcher(store: store).runningPID(instance.index) != nil else {
            throw KestrelError.runtime("\(instance.settings.name) is not running")
        }
        guard Self.hasAccessibility(prompt: true) else {
            throw KestrelError.environment("Kestrel needs the Accessibility permission to read game keys. Enable Kestrel in System Settings → Privacy & Security → Accessibility, then try again.")
        }
        let problems = keymap.validate()
        guard problems.isEmpty else { throw KestrelError.invalid("keymap: " + problems.joined(separator: "; ")) }
        let s = instance.settings
        let size = inputSize ?? (width: s.width, height: s.height)
        guard size.width > 0, size.height > 0,
              size.width <= PlayerFrame.maximumDimension, size.height <= PlayerFrame.maximumDimension else {
            throw KestrelError.invalid("Invalid keymap input dimensions")
        }
        let sink: TouchSink = try suppliedSink ?? DeviceSink(adb: ADB(sdk: store.sdk, serial: instance.ports.serial), width: s.width, height: s.height)
        let recorder = record ? InputRecorder() : nil
        let driver = Driver(engine: KeymapEngine(keymap: keymap, screenWidth: size.width, screenHeight: size.height,
                                                 sensitivity: s.mouseSensitivity),
                            sink: sink, recorder: recorder)
        driver.onError = { e in DispatchQueue.main.async { onStatus("\(e)") } }
        let controller = PlayController(driver: driver, keymap: keymap, consolePort: instance.ports.console,
                                        windowProvider: windowProvider, hintParentWindow: hintParentWindow)
        controller.onStatus = onStatus
        guard controller.start() else {
            controller.stop()
            driver.stop()
            throw KestrelError.environment("Could not read the keyboard. Enable Kestrel in System Settings → Privacy & Security → Accessibility.")
        }
        driver.startTicking()
        self.instanceIndex = instance.index
        self.keymap = keymap
        self.driver = driver
        self.controller = controller
        self.recorder = recorder
    }

    public var isRecording: Bool { recorder != nil }
    public func setHintOpacity(_ value: Double) { controller.setHintOpacity(value) }
    public func setInputSuspended(_ suspended: Bool) { controller.setInputSuspended(suspended) }

    /// Stops listening, lifts every finger and closes the touch channel. Returns the
    /// recording when the session was recording.
    @discardableResult
    public func stop() -> InputRecording? {
        guard !stopped else { return nil }
        stopped = true
        controller.stop()
        driver.stop()
        return recorder?.recording
    }

    deinit { stop() }
}
