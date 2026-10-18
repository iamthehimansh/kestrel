import AppKit
import ApplicationServices
import GameController
import KestrelCore
import KestrelKeymap

/// Captures keyboard, mouse and gamepad input while the emulator window is focused and
/// drives touches into the guest. Shows key hints over the emulator window.
///
/// Requires the Accessibility permission (for the event tap that swallows mapped keys
/// so the emulator does not also receive them).
public enum PlaySession {
    public static func run(instance: Instance, store: InstanceStore, keymap: Keymap, dryRun: Bool, recordTo: URL? = nil) throws {
        guard dryRun || Launcher(store: store).runningPID(instance.index) != nil else {
            throw KestrelError.runtime("instance \(instance.index) is not running; start it with `kestrel start \(instance.index) --wait`")
        }
        if !dryRun && !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
            throw KestrelError.environment("""
            kestrel needs the Accessibility permission to read game keys.
            Open System Settings → Privacy & Security → Accessibility, enable your terminal app, then run play again.
            """)
        }

        let s = instance.settings
        let sink: TouchSink = dryRun ? PrintSink() : try DeviceSink(adb: ADB(sdk: store.sdk, serial: instance.ports.serial),
                                                                     width: s.width, height: s.height)
        let engine = KeymapEngine(keymap: keymap, screenWidth: s.width, screenHeight: s.height, sensitivity: s.mouseSensitivity)
        let recorder = recordTo.map { _ in InputRecorder() }
        let driver = Driver(engine: engine, sink: sink, recorder: recorder)
        driver.onError = { e in
            FileHandle.standardError.write(Data("kestrel: \(e)\n".utf8))
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = PlayController(driver: driver, keymap: keymap, consolePort: instance.ports.console)
        controller.onStatus = { print($0) }
        controller.start()
        driver.startTicking()

        print("Playing with keymap '\(keymap.name)'. \(keymap.resolvedLookToggle) toggles mouse-look, \(keymap.resolvedFreeCursor) frees the cursor, F12 hides hints. Ctrl-C to quit.")
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            controller.stop()
            driver.stop()
            if let recordTo, let recorder {
                do {
                    try recorder.recording.serialized().write(to: recordTo, atomically: true, encoding: .utf8)
                    print("\nSaved \(recorder.recording.entries.count) events to \(recordTo.path)")
                } catch {
                    FileHandle.standardError.write(Data("kestrel: could not save recording: \(error)\n".utf8))
                }
            }
            print("\nStopped.")
            exit(0)
        }
        sigint.resume()
        app.run()
    }
}

final class PlayController {
    let driver: Driver
    let keymap: Keymap
    let consolePort: Int
    private let windowProvider: (() -> (frame: CGRect?, focused: Bool))?
    private var nativePointerDown = false
    func setHintOpacity(_ value: Double) { overlay?.setOpacity(value) }
    /// Short status lines for whoever hosts the session (stdout for the CLI, the app's UI).
    var onStatus: ((String) -> Void)?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var connectObserver: NSObjectProtocol?
    private var overlay: HintOverlay?
    private var windowTimer: Timer?
    private var emulatorFrame: CGRect?
    private var focused = false
    private var cursorLocked = false
    private var controllers: [GCController] = []

    init(driver: Driver, keymap: Keymap, consolePort: Int,
         windowProvider: (() -> (frame: CGRect?, focused: Bool))? = nil) {
        self.driver = driver
        self.keymap = keymap
        self.consolePort = consolePort
        self.windowProvider = windowProvider
    }

    /// False when the event tap could not be created (no Accessibility permission).
    @discardableResult
    func start() -> Bool {
        let ok = installEventTap()
        overlay = HintOverlay(keymap: keymap)
        windowTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.trackWindow() }
        trackWindow()
        setupGamepads()
        return ok
    }

    /// Tears everything down so the controller can be released while the host keeps running.
    func stop() {
        windowTimer?.invalidate()
        windowTimer = nil
        unlockCursor()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        tapSource = nil
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver) }
        connectObserver = nil
        for c in controllers { detach(c) }
        controllers.removeAll()
        overlay?.close()
        overlay = nil
        focused = false
    }

    // MARK: - Emulator window

    /// Finds this instance's window (title "Android Emulator - <avd>:<console port>") and
    /// decides whether it is the window the user is typing into: it must be the frontmost
    /// normal window of the frontmost app. Checking the app alone is not enough, because
    /// every instance runs the same emulator binary, and two running instances would both
    /// grab the keyboard.
    private func trackWindow() {
        if let windowProvider {
            let state = windowProvider()
            emulatorFrame = state.frame
            applyFocus(state.focused && state.frame != nil, frame: state.frame)
            return
        }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let marker = ":\(consolePort)"
        var frame: CGRect?
        var ownerPID: pid_t?
        for w in list {
            guard let name = w[kCGWindowName as String] as? String, name.hasSuffix(marker),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if r.width > 100 && r.height > 100 {
                frame = r
                ownerPID = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                break
            }
        }
        emulatorFrame = frame
        var nowFocused = false
        if frame != nil, let ownerPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == ownerPID {
            // On-screen windows come front to back; the first normal (layer 0) window of the
            // frontmost app is the one with keyboard focus.
            let front = list.first { w in
                (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID
                    && (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
            }
            nowFocused = (front?[kCGWindowName as String] as? String)?.hasSuffix(marker) == true
        }
        applyFocus(nowFocused, frame: frame)
    }

    private func applyFocus(_ nowFocused: Bool, frame: CGRect?) {
        if nowFocused != focused {
            focused = nowFocused
            if !focused {
                nativePointerDown = false
                unlockCursor()
                driver.post(.reset)
            }
        }
        overlay?.update(frame: frame.map(contentRect), visible: focused, look: driver.sync { $0.lookMode })
        if focused && driver.sync({ $0.lookMode }) { lockCursor() } else { unlockCursor() }
    }

    /// Strips the emulator's title bar (28 pt) so normalized coordinates match the screen.
    private func contentRect(_ r: CGRect) -> CGRect {
        if windowProvider != nil { return r }
        let title: CGFloat = 28
        return CGRect(x: r.minX, y: r.minY + title, width: r.width, height: max(1, r.height - title))
    }

    private func lockCursor() {
        guard !cursorLocked, let f = emulatorFrame else { return }
        cursorLocked = true
        CGAssociateMouseAndMouseCursorPosition(0)
        CGDisplayHideCursor(CGMainDisplayID())
        let c = contentRect(f)
        CGWarpMouseCursorPosition(CGPoint(x: c.midX, y: c.midY))
    }

    private func unlockCursor() {
        guard cursorLocked else { return }
        cursorLocked = false
        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
    }

    // MARK: - Event tap

    private func installEventTap() -> Bool {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .mouseMoved, .leftMouseDown, .leftMouseUp,
                                    .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            let ctl = Unmanaged<PlayController>.fromOpaque(refcon!).takeUnretainedValue()
            return ctl.handle(type: type, event: event)
        }, userInfo: me) else {
            onStatus?("Could not read the keyboard: give Kestrel the Accessibility permission.")
            return false
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        tapSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private var mappedKeys: Set<String> {
        Set(keymap.controls.flatMap(\.keys) + [keymap.resolvedLookToggle, keymap.resolvedFreeCursor])
    }

    private var modifierState: [String: Bool] = [:]

    /// Returns nil to swallow the event (mapped key while focused), or the event to pass through.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if let windowProvider {
            let state = windowProvider()
            emulatorFrame = state.frame
            let nowFocused = state.focused && state.frame != nil
            if nowFocused != focused { applyFocus(nowFocused, frame: state.frame) }
        }
        guard focused else { return Unmanaged.passUnretained(event) }
        let pass = Unmanaged.passUnretained(event)
        if windowProvider != nil {
            let look = driver.sync { $0.effectiveLook }
            if look && nativePointerDown {
                driver.post(.pointerUp)
                nativePointerDown = false
            }
            if type == .leftMouseUp && nativePointerDown {
                nativePointerDown = false
                driver.post(.pointerUp)
                return nil
            }
            if !look, type == .leftMouseDown, let frame = emulatorFrame {
                let rect = contentRect(frame)
                guard rect.width > 0, rect.height > 0, rect.contains(event.location) else { return pass }
                nativePointerDown = true
                driver.post(.pointerDown(NPoint((event.location.x - rect.minX) / rect.width,
                                               (event.location.y - rect.minY) / rect.height)))
                return nil
            }
        }

        switch type {
        case .keyDown, .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if code == 0x6F { // F12 toggles hints
                if type == .keyDown { overlay?.toggleHidden() }
                return nil
            }
            guard let key = KeyNames.macKeyCodes[code] else { return pass }
            // Cmd shortcuts (Cmd-Tab, Cmd-Q…) always go to macOS.
            if event.flags.contains(.maskCommand) { return pass }
            guard mappedKeys.contains(key) else { return pass }
            driver.post(type == .keyDown ? .keyDown(key) : .keyUp(key))
            if key == keymap.resolvedLookToggle && type == .keyDown {
                DispatchQueue.main.async { self.trackWindow() }
            }
            return nil

        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let key = KeyNames.macKeyCodes[code] else { return pass }
            let flag: CGEventFlags
            switch key {
            case "Shift", "RightShift": flag = .maskShift
            case "Ctrl", "RightCtrl": flag = .maskControl
            case "Alt", "RightAlt": flag = .maskAlternate
            case "Cmd", "RightCmd": flag = .maskCommand
            case "CapsLock": flag = .maskAlphaShift
            default: return pass
            }
            let down = event.flags.contains(flag) && modifierState[key] != true
            let up = modifierState[key] == true
            guard down || up, mappedKeys.contains(key) else { modifierState[key] = event.flags.contains(flag); return pass }
            modifierState[key] = down
            driver.post(down ? .keyDown(key) : .keyUp(key))
            if key == keymap.resolvedFreeCursor { DispatchQueue.main.async { self.trackWindow() } }
            return nil

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if cursorLocked {
                let dx = event.getDoubleValueField(.mouseEventDeltaX)
                let dy = event.getDoubleValueField(.mouseEventDeltaY)
                driver.post(.mouseMove(dx: dx, dy: dy))
                return nil
            }
            if let f = emulatorFrame {
                let c = contentRect(f), p = event.location
                let point = NPoint((p.x - c.minX) / c.width, (p.y - c.minY) / c.height)
                driver.post(.cursor(point))
                if windowProvider != nil, nativePointerDown, type == .leftMouseDragged {
                    driver.post(.pointerMove(point))
                    return nil
                }
            }
            return pass

        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let key: String
            switch type {
            case .leftMouseDown, .leftMouseUp: key = "MouseLeft"
            case .rightMouseDown, .rightMouseUp: key = "MouseRight"
            default:
                switch event.getIntegerValueField(.mouseEventButtonNumber) {
                case 2: key = "MouseMiddle"
                case 3: key = "Mouse4"
                case 4: key = "Mouse5"
                default: return pass
                }
            }
            let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(type)
            // In cursor mode an unmapped click must still reach Android as a normal touch.
            let live = driver.sync { engine in
                engine.lookMode || keymap.controls.contains { $0.keys.contains(key) && $0.mode != .look }
            }
            // With the cursor locked, an unmapped click would land as a stray touch at the
            // hidden cursor, so swallow it.
            if cursorLocked && !mappedKeys.contains(key) { return nil }
            guard live, mappedKeys.contains(key) else { return pass }
            driver.post(down ? .keyDown(key) : .keyUp(key))
            return nil

        case .scrollWheel:
            let dy = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            guard dy != 0, mappedKeys.contains(dy > 0 ? "WheelUp" : "WheelDown") else { return pass }
            driver.post(.wheel(dy))
            driver.post(.keyUp(dy > 0 ? "WheelUp" : "WheelDown"))
            return nil

        default:
            return pass
        }
    }

    // MARK: - Gamepad

    private func setupGamepads() {
        connectObserver = NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            if let c = n.object as? GCController { self?.attach(c) }
        }
        GCController.controllers().forEach(attach)
        GCController.startWirelessControllerDiscovery {}
    }

    private func detach(_ c: GCController) {
        guard let pad = c.extendedGamepad else { return }
        pad.leftThumbstick.valueChangedHandler = nil
        pad.rightThumbstick.valueChangedHandler = nil
        for b in [pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY, pad.leftShoulder, pad.rightShoulder,
                  pad.leftTrigger, pad.rightTrigger, pad.leftThumbstickButton, pad.rightThumbstickButton,
                  pad.dpad.up, pad.dpad.down, pad.dpad.left, pad.dpad.right, pad.buttonMenu, pad.buttonOptions, pad.buttonHome] {
            b?.pressedChangedHandler = nil
        }
    }

    private func attach(_ c: GCController) {
        guard let pad = c.extendedGamepad, !controllers.contains(where: { $0 === c }) else { return }
        controllers.append(c)
        onStatus?("Gamepad connected: \(c.vendorName ?? "controller")")
        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            guard self?.focused == true else { return }
            self?.driver.post(.stick(name: "left", x: Double(x), y: Double(-y)))
        }
        pad.rightThumbstick.valueChangedHandler = { [weak self] _, x, y in
            guard self?.focused == true else { return }
            self?.driver.post(.stick(name: "right", x: Double(x), y: Double(-y)))
        }
        let buttons: [(GCControllerButtonInput?, String)] = [
            (pad.buttonA, "Pad.A"), (pad.buttonB, "Pad.B"), (pad.buttonX, "Pad.X"), (pad.buttonY, "Pad.Y"),
            (pad.leftShoulder, "Pad.L1"), (pad.rightShoulder, "Pad.R1"),
            (pad.leftTrigger, "Pad.L2"), (pad.rightTrigger, "Pad.R2"),
            (pad.leftThumbstickButton, "Pad.L3"), (pad.rightThumbstickButton, "Pad.R3"),
            (pad.dpad.up, "Pad.Up"), (pad.dpad.down, "Pad.Down"), (pad.dpad.left, "Pad.Left"), (pad.dpad.right, "Pad.Right"),
            (pad.buttonMenu, "Pad.Menu"), (pad.buttonOptions, "Pad.Options"), (pad.buttonHome, "Pad.Home"),
        ]
        for (button, name) in buttons {
            button?.pressedChangedHandler = { [weak self] _, _, pressed in
                guard self?.focused == true else { return }
                self?.driver.post(pressed ? .keyDown(name) : .keyUp(name))
            }
        }
    }
}

/// Click-through transparent window that labels each control over the emulator.
final class HintOverlay {
    private let window: NSWindow
    private let view: HintView
    private var hidden = false

    init(keymap: Keymap) {
        view = HintView(keymap: keymap)
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .floating
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = view
    }

    func setOpacity(_ value: Double) {
        guard value.isFinite else { return }
        window.alphaValue = min(1, max(0, value))
    }

    func toggleHidden() { hidden.toggle(); view.needsDisplay = true; if hidden { window.orderOut(nil) } }

    /// `frame` is in CoreGraphics (top-left origin) global coordinates.
    func update(frame: CGRect?, visible: Bool, look: Bool) {
        guard let frame, visible, !hidden else { window.orderOut(nil); return }
        let screenH = NSScreen.screens.first?.frame.height ?? 0
        let r = NSRect(x: frame.minX, y: screenH - frame.maxY, width: frame.width, height: frame.height)
        if window.frame != r { window.setFrame(r, display: true) }
        if view.look != look { view.look = look; view.needsDisplay = true }
        window.orderFrontRegardless()
    }

    func close() { window.orderOut(nil) }
}

final class HintView: NSView {
    let keymap: Keymap
    var look = false

    init(keymap: Keymap) {
        self.keymap = keymap
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        for c in keymap.controls {
            switch c.mode {
            case .look where !look: continue
            case .cursor where look: continue
            default: break
            }
            let p = c.anchor
            let center = CGPoint(x: p.x * w, y: p.y * h)
            switch c {
            case .joystick(let j):
                let r = j.radius * w
                stroke(circle: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                let keys = [j.up, j.left, j.down, j.right].compactMap { $0 }.joined()
                label(keys.isEmpty ? "🕹" : keys, at: center)
            case .look(let l):
                if look {
                    let r = l.radius * w * 0.25
                    stroke(circle: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
                }
            case .macro(let m):
                label("⚙︎" + KeyNames.shortLabel(m.key), at: CGPoint(x: 0.03 * w, y: 0.5 * h))
            case .scroll, .pinch:
                label(c.keys.map(KeyNames.shortLabel).joined(separator: "/"), at: center)
            default:
                label(c.keys.map(KeyNames.shortLabel).first ?? "", at: center)
            }
        }
        let mode = look ? "AIM  \(KeyNames.shortLabel(keymap.resolvedLookToggle)) to free cursor" : "CURSOR  \(KeyNames.shortLabel(keymap.resolvedLookToggle)) to aim"
        label(mode, at: CGPoint(x: w / 2, y: 14), small: true)
    }

    private func stroke(circle r: CGRect) {
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let path = NSBezierPath(ovalIn: r)
        path.lineWidth = 1.5
        path.stroke()
    }

    private func label(_ text: String, at p: CGPoint, small: Bool = false) {
        let font = NSFont.systemFont(ofSize: small ? 11 : 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let box = CGRect(x: p.x - size.width / 2 - 6, y: p.y - size.height / 2 - 3, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: box, xRadius: box.height / 2, yRadius: box.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
    }
}
