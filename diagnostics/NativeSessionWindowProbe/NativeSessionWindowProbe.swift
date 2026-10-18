import AppKit
import Darwin
import Metal
import KestrelCore
import KestrelPlay
import KestrelKeymap

@available(macOS 15, *)
@MainActor
private final class WindowProbe: NSObject, NSApplicationDelegate {
    var controller: NativePlayerSessionController?
    var store: InstanceStore?
    var passed = false
    var timedOut = false
    var replayCancelled = false
    var inputFailureMode = false
    var rotationInspectMode = false
    var inputFailureInjected = false
    var inputErrorReported = false
    var closeStarted: Date?
    var heartbeat: Timer?
    let began = Date()

    func log(_ text: String) {
        print("[\(Date())] \(text)")
        fflush(stdout)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "--cursor-check" {
                Task {
                    do { try await checkCursor(); exit(0) }
                    catch { log("[1/1] Cursor check failed: \(error)"); exit(1) }
                }
                return
            }
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--sidebar-check" {
                Task {
                    do { try await checkSidebar(to: URL(fileURLWithPath: CommandLine.arguments[2])); exit(0) }
                    catch { log("Sidebar verification failed: \(error)"); exit(1) }
                }
                return
            }
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--overlay-check" {
                Task {
                    do { try await checkOverlay(to: URL(fileURLWithPath: CommandLine.arguments[2])); exit(0) }
                    catch { log("Overlay verification failed: \(error)"); exit(1) }
                }
                return
            }
            if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--splash-capture" {
                Task {
                    do {
                        try await captureSplash(to: URL(fileURLWithPath: CommandLine.arguments[2]))
                        exit(0)
                    } catch {
                        log("[1/1] Splash capture failed: \(error)")
                        exit(1)
                    }
                }
                return
            }
            inputFailureMode = CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "--input-failure"
            rotationInspectMode = CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "--rotation-inspect"
            guard CommandLine.arguments.count == 3 || inputFailureMode || rotationInspectMode,
                  let raw = realpath(CommandLine.arguments[1], nil) else {
                throw KestrelError.invalid("Expected disposable profile and SDK")
            }
            let path = String(cString: raw)
            free(raw)
            let parts = path.split(separator: "/")
            guard parts.count == 3, parts[0] == "private", parts[1] == "tmp",
                  parts[2].hasPrefix("kestrel-perf-") else {
                throw KestrelError.invalid("Not a disposable profile")
            }
            let store = InstanceStore(paths: KestrelPaths(root: URL(fileURLWithPath: path)),
                sdk: AndroidSDK(root: URL(fileURLWithPath: CommandLine.arguments[2])))
            self.store = store
            guard try store.load(0).settings.name == "Startup probe", Launcher(store: store).runningPID(0) == nil,
                  let gpu = MTLCreateSystemDefaultDevice() else { throw KestrelError.invalid("Unsafe fixture or missing GPU") }
            let controller = try NativePlayerSessionController(store: store, index: 0, port: 8556,
                title: "Session lifecycle diagnostic", width: 1280, height: 720, device: gpu)
            self.controller = controller
            controller.onReady = { [weak self] in self?.ready() }
            controller.onStopped = { [weak self] result in self?.stopped(result) }
            controller.onCommandError = { [weak self] _ in self?.inputErrorReported = true }
            heartbeat = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.log("[2/4] Active \(Int(Date().timeIntervalSince(self.began)))s; awaiting renewal and cleanup")
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(90))
                guard let self, !self.passed else { return }
                self.timedOut = true
                self.controller?.stop()
            }
            log("[1/4] Starting native window and owned VM")
            controller.start(coldBoot: true)
        } catch { log("[4/4] FAILED setup: \(type(of: error))"); exit(1) }
    }

    func checkCursor() async throws {
        guard let gpu = MTLCreateSystemDefaultDevice(), let original = CGEvent(source: nil)?.location,
              let screen = NSScreen.screens.first else { throw KestrelError.runtime("Missing cursor test environment") }
        let previousApp = NSWorkspace.shared.frontmostApplication
        let player = try PlayerWindowController(title: "Cursor verification", device: gpu)
        defer {
            player.close()
            CGWarpMouseCursorPosition(original)
            previousApp?.activate(options: [])
        }
        guard let window = player.window, let content = window.contentView else { throw KestrelError.runtime("Missing window") }
        player.showWindow(nil)
        let stream = player.beginConnection()
        let frame = try PlayerFrame(width: 640, height: 360, bytesPerRow: 640 * 4,
            sequence: 1, timestampMicroseconds: 1, rgba: Data(repeating: 255, count: 640 * 360 * 4))
        guard player.frameView.mailbox.offer(frame, stream: stream) else {
            throw KestrelError.runtime("Test frame was rejected")
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        content.layoutSubtreeIfNeeded()
        window.invalidateCursorRects(for: player.frameView)
        func move(to point: NSPoint) {
            let quartz = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
            CGWarpMouseCursorPosition(quartz)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: quartz,
                    mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        try await Task.sleep(for: .milliseconds(300))
        let view = player.frameView
        move(to: window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)))
        try await Task.sleep(for: .milliseconds(300))
        guard NSCursor.current.hotSpot == NSPoint(x: 3, y: 2),
              NSCursor.current.image.size == NSSize(width: 24, height: 32) else {
            throw KestrelError.runtime("Game view did not select its custom cursor")
        }
        log("[1/2] Game view selected the custom tip-hotspot cursor")
        move(to: window.convertPoint(toScreen: NSPoint(x: 40, y: content.bounds.maxY - 20)))
        try await Task.sleep(for: .milliseconds(300))
        guard NSCursor.current.hotSpot != NSPoint(x: 3, y: 2) ||
              NSCursor.current.image.size != NSSize(width: 24, height: 32) else {
            throw KestrelError.runtime("Custom cursor leaked onto toolbar")
        }
        log("[2/3] Toolbar restored normal cursor")
        @MainActor func buttons(in root: NSView) -> [NSButton] {
            (root as? NSButton).map { [$0] } ?? root.subviews.flatMap { buttons(in: $0) }
        }
        for title in ["Smaller", "Larger"] {
            guard let button = buttons(in: content).first(where: { $0.title == title }) else {
                throw KestrelError.runtime("Missing display-size button")
            }
            let before = window.frame.size
            button.performClick(nil)
            content.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let after = window.frame.size
            guard title == "Smaller" ? after.width < before.width : after.width > before.width else {
                throw KestrelError.runtime("Display-size button did not resize window")
            }
            guard let pixel = view.pixel(at: NSPoint(x: view.bounds.midX, y: view.bounds.midY)),
                  abs(pixel.x - 320) <= 1, abs(pixel.y - 180) <= 1,
                  view.screenshotFrame()?.width == 640, view.screenshotFrame()?.height == 360 else {
                throw KestrelError.runtime("Display resize changed guest geometry or center input mapping")
            }
        }
        log("[3/5] Smaller/Larger preserved guest frame and center mapping")
        guard let controls = buttons(in: content).first(where: { $0.title == "Controls" }),
              let fullScreen = buttons(in: content).first(where: { $0.title == "Full screen" }),
              let hide = buttons(in: content).first(where: { $0.title == "Hide" }) else {
            throw KestrelError.runtime("Missing window controls")
        }
        controls.performClick(nil)
        guard !player.sidePanelVisible else { throw KestrelError.runtime("Side panel did not hide") }
        controls.performClick(nil)
        guard player.sidePanelVisible else { throw KestrelError.runtime("Side panel did not return") }
        @MainActor func waitFor(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !condition() && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            guard condition() else { throw KestrelError.runtime("Window transition timed out") }
        }
        fullScreen.performClick(nil)
        try await waitFor { window.styleMask.contains(.fullScreen) }
        try await Task.sleep(for: .seconds(1))
        fullScreen.performClick(nil)
        try await waitFor { !window.styleMask.contains(.fullScreen) }
        try await Task.sleep(for: .seconds(1))
        log("[4/5] Side panel and full-screen round trips passed")
        hide.performClick(nil)
        try await waitFor { window.isMiniaturized }
        window.deminiaturize(nil)
        try await waitFor { !window.isMiniaturized }
        log("[5/5] Minimize/restore passed; SUMMARY: native window controls passed")
    }

    func checkSidebar(to directory: URL) async throws {
        log("[1/3] Open offline sidebar fixture; no Android commands")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let gpu = MTLCreateSystemDefaultDevice() else { throw KestrelError.runtime("No Metal device") }
        let player = try PlayerWindowController(title: "Sidebar verification", device: gpu)
        defer { player.close() }
        guard let window = player.window, let content = window.contentView else { throw KestrelError.runtime("No window") }
        window.setContentSize(NSSize(width: 1000, height: 620))
        player.showWindow(nil)
        let stream = player.beginConnection()
        var pixels = Data()
        pixels.reserveCapacity(640 * 360 * 4)
        for index in 0..<(640 * 360) {
            let red = UInt8(20 + (index % 640) / 8)
            let green = UInt8(30 + (index / 640) / 4)
            pixels.append(contentsOf: [red, green, 80, 255])
        }
        let frame = try PlayerFrame(width: 640, height: 360, bytesPerRow: 2560,
                                   sequence: 1, timestampMicroseconds: 1, rgba: pixels)
        _ = player.frameView.mailbox.offer(frame, stream: stream)
        var requests: [Bool] = []
        player.onKeymappingChanged = { enabled in requests.append(enabled); player.setKeymappingEnabled(enabled) }
        defer { player.onKeymappingChanged = nil }
        @MainActor func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { descendants($0) } }
        content.layoutSubtreeIfNeeded()
        guard let button = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Keymapping controls" }) else {
            throw KestrelError.runtime("Missing sidebar control")
        }
        button.performClick(nil)
        try await Task.sleep(for: .milliseconds(400))
        guard let popover = NSApp.windows.first(where: { candidate in
            guard let view = candidate.contentView else { return false }
            return descendants(view).contains { ($0 as? NSButton)?.title == "Enable keymapping" }
        }), let popoverContent = popover.contentView,
              let toggle = descendants(popoverContent).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Enable keymapping" }),
              let slider = descendants(popoverContent).compactMap({ $0 as? NSSlider }).first else {
            throw KestrelError.runtime("Sidebar popover missing controls")
        }
        log("[2/3] Exercise mapping toggle and 0/50/100 percent hint visibility")
        toggle.performClick(nil)
        guard player.keymappingEnabled else { throw KestrelError.runtime("Toggle did not enable") }
        for value in [0.0, 0.5, 1.0] {
            slider.doubleValue = value
            slider.sendAction(slider.action, to: slider.target)
            guard player.hintOpacity == value, player.keymappingEnabled, player.frameView.alphaValue == 1,
                  descendants(popoverContent).contains(where: { ($0 as? NSTextField)?.stringValue == "Hint visibility: \(Int(value * 100))%" }) else {
                throw KestrelError.runtime("Opacity affected mapping/video or label was wrong")
            }
        }
        slider.doubleValue = 0.5
        slider.sendAction(slider.action, to: slider.target)
        try await Task.sleep(for: .milliseconds(200))
        log("[3/3] Capture sidebar popover and verify disable")
        let number = popover.windowNumber
        try await Task.detached {
            try PlayerCommandProcess.run(executable: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                arguments: ["-x", "-o", "-l", String(number), directory.appendingPathComponent("sidebar-controls.png").path], timeout: 5)
        }.value
        toggle.performClick(nil)
        guard !player.keymappingEnabled, requests == [true, false] else { throw KestrelError.runtime("Disable failed") }
        button.performClick(nil) // Close the transient popover before resizing its anchor.
        guard let scroll = descendants(content).compactMap({ $0 as? NSScrollView }).first(where: {
            $0.identifier?.rawValue == "player.actionScroll"
        }), let rail = scroll.documentView as? NSStackView else {
            throw KestrelError.runtime("Sidebar must have a scrollable action document")
        }
        let actions = rail.arrangedSubviews.compactMap { $0 as? NSButton }
        guard actions.count == PlayerWindowAction.allCases.count + 1 else {
            throw KestrelError.runtime("Sidebar lost an action")
        }
        for size in [NSSize(width: 560, height: 338), NSSize(width: 560, height: 360),
                     NSSize(width: 1000, height: 620)] {
            window.setContentSize(size)
            content.layoutSubtreeIfNeeded()
            guard abs(scroll.bounds.width - 52) < 1,
                  abs(scroll.bounds.height - (content.bounds.height - 44)) < 1 else {
                throw KestrelError.runtime("Sidebar viewport no longer fits the player")
            }
            var previousMaxY: CGFloat = 0
            for action in actions {
                let rect = action.convert(action.bounds, to: rail)
                guard action.superview === rail, !action.isHidden,
                      abs(rect.height - 36) < 1, abs(rect.width - 36) < 1,
                      rect.minY >= previousMaxY else {
                    throw KestrelError.runtime("Sidebar action collapsed, detached or overlapped: \(action.title)")
                }
                previousMaxY = rect.maxY
                rail.scrollToVisible(rect)
                content.layoutSubtreeIfNeeded()
                guard rail.visibleRect.insetBy(dx: -1, dy: -1).contains(rect) else {
                    throw KestrelError.runtime("Sidebar action cannot scroll into view: \(action.title)")
                }
            }
        }
        log("SUMMARY: sidebar toggles, opacity and every action at short/tall sizes exercised; screenshot saved; no VM or user app changed")
    }

    func checkOverlay(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let gpu = MTLCreateSystemDefaultDevice() else { throw KestrelError.runtime("No Metal device") }
        let player = try PlayerWindowController(title: "Live controls verification", device: gpu)
        defer { player.close() }
        guard let window = player.window, let content = window.contentView else { throw KestrelError.runtime("No window") }
        window.setContentSize(NSSize(width: 1000, height: 620))
        player.showWindow(nil)
        let stream = player.beginConnection()
        let pixels = Data((0..<(640 * 360)).flatMap { index -> [UInt8] in
            let x = index % 640, y = index / 640
            return [UInt8(20 + x / 8), UInt8(30 + y / 4), 80, 255]
        })
        let frame = try PlayerFrame(width: 640, height: 360, bytesPerRow: 2560,
                                   sequence: 1, timestampMicroseconds: 1, rgba: pixels)
        _ = player.frameView.mailbox.offer(frame, stream: stream)
        let keymap = Keymap(name: "Live controls", controls: [
            .tap(TapControl(key: "Q", at: NPoint(0.2, 0.5))),
            .tap(TapControl(key: "Space", at: NPoint(0.78, 0.7)))
        ])
        var saved: Keymap?
        var dismissed = 0
        player.showKeymapEditor(keymap, aspect: 640.0 / 360, save: { saved = $0 }, dismissed: { dismissed += 1 })
        content.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        guard player.isEditingKeymap, player.isConnected, !player.perform(.home) else {
            throw KestrelError.runtime("Editing did not isolate input")
        }
        @MainActor func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { descendants($0) } }
        guard let canvas = descendants(content).compactMap({ $0 as? KeymapCanvasView }).first else {
            throw KestrelError.runtime("No live keymap canvas")
        }
        canvas.setSelected(0, notify: true)
        guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "e",
            charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 0x0E) else { throw KestrelError.runtime("No key event") }
        canvas.keyDown(with: key)
        let number = window.windowNumber
        let destination = directory.appendingPathComponent("live-overlay-landscape.png")
        try await Task.detached {
            try PlayerCommandProcess.run(executable: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                arguments: ["-x", "-o", "-l", String(number), destination.path], timeout: 5)
        }.value
        guard let saveButton = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Save" }) else {
            throw KestrelError.runtime("No Save control")
        }
        saveButton.performClick(nil)
        guard let first = saved?.controls.first, case .tap(let tap) = first,
              tap.key == "E", dismissed == 1, !player.isEditingKeymap, player.isConnected else {
            throw KestrelError.runtime("Rebind/save failed")
        }
        player.showKeymapEditor(keymap, aspect: 640.0 / 360, save: { _ in
            throw KestrelError.runtime("Cancel must not save")
        }, dismissed: { dismissed += 1 })
        guard let cancel = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" }) else {
            throw KestrelError.runtime("No Cancel control")
        }
        cancel.performClick(nil)
        guard dismissed == 2, !player.isEditingKeymap, player.isConnected else { throw KestrelError.runtime("Cancel failed") }
        log("SUMMARY: overlay over rendered test frame, key rebinding, Save and Cancel passed; no guest touched")
    }

    func captureSplash(to directory: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let gpu = MTLCreateSystemDefaultDevice() else { throw KestrelError.runtime("No Metal device") }
        let player = try PlayerWindowController(title: "Splash verification", device: gpu)
        defer { player.close() }
        guard let window = player.window, let view = window.contentView else { throw KestrelError.runtime("Missing view") }
        window.setContentSize(NSSize(width: 560, height: 360))
        player.showBootProgress("Starting Android…")
        player.showWindow(nil)
        for (name, size) in [("landscape", NSSize(width: 1000, height: 620)),
                             ("portrait", NSSize(width: 560, height: 820)),
                             ("minimum", NSSize(width: 560, height: 360))] {
            window.setContentSize(size)
            window.appearance = NSAppearance(named: .darkAqua)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            let number = window.windowNumber
            let destination = directory.appendingPathComponent("splash-\(name).png")
            try await Task.detached {
                try PlayerCommandProcess.run(executable: URL(fileURLWithPath: "/usr/sbin/screencapture"),
                    arguments: ["-x", "-o", "-l", String(number), destination.path], timeout: 5)
            }.value
            log("[1/1] Captured \(name) splash at minimum content size")
        }
    }

    nonisolated static func captureADB(adb: URL, arguments: [String]) throws -> String {
        let child = Process()
        child.executableURL = adb
        child.arguments = arguments
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-focus-\(UUID()).txt")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        child.standardOutput = file
        child.standardError = file
        let ended = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in ended.signal() }
        try child.run()
        guard ended.wait(timeout: .now() + 5) == .success else {
            child.terminate()
            throw KestrelError.runtime("Focus capture timed out")
        }
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let bytes = try reader.read(upToCount: 1_048_576) ?? Data()
        guard child.terminationStatus == 0 else {
            print("Diagnostic command failed: \(arguments.joined(separator: " ")); exit \(child.terminationStatus)")
            print(String(decoding: bytes.prefix(16_384), as: UTF8.self))
            fflush(stdout)
            throw KestrelError.runtime("Diagnostic ADB command failed")
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    nonisolated static func focusedWindow(adb: URL, serial: String) throws -> String {
        let text = try captureADB(adb: adb, arguments: ["-s", serial, "shell",
            "echo SECTION_WINDOWS; dumpsys window windows; echo SECTION_DISPLAYS; dumpsys window displays"])
        var section = "unknown"
        var focus: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("SECTION_") { section = line }
            if line.contains("mCurrentFocus=") {
                print("Focus evidence [\(section)]: \(line)")
                focus.append(line)
            }
        }
        fflush(stdout)
        guard focus.count == 1 else {
            throw KestrelError.runtime("Missing or ambiguous current window focus")
        }
        return focus[0]
    }

    func injectInputFailure() {
        Task { [self] in
            do {
                guard let store, let controller else { throw KestrelError.runtime("Missing fixture") }
                let adb = store.sdk.adb
                let serial = Ports.forInstance(0).serial
                try await Task.detached {
                    let text = try Self.captureADB(adb: adb, arguments: ["-s", serial, "shell", "pidof", "kestrel-touchd"])
                    let pids = text.split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
                    guard pids.count == 1, let pid = pids.first, pid > 1 else {
                        throw KestrelError.runtime("Expected exactly one diagnostic touch helper")
                    }
                    try PlayerCommandProcess.run(executable: adb,
                        arguments: ["-s", serial, "shell", "kill", "-TERM", String(pid)], timeout: 5)
                }.value
                try await Task.sleep(for: .milliseconds(300))
                let lease = try controller.acquireKeymapInput()
                inputFailureInjected = true
                closeStarted = Date()
                try lease.send([.down(slot: 0, x: 640, y: 360)])
                log("[2/4] Touch helper stopped; queued input must trigger failure and automatic cleanup")
            } catch {
                log("[2/4] Failure injection could not complete: \(type(of: error))")
                controller?.stop()
            }
        }
    }

    func verifyRotatedTouch(_ orientation: PlayerRotation, adb: URL, serial: String) async throws {
        func command(_ args: [String]) async throws -> String {
            try await Task.detached {
                try Self.captureADB(adb: adb, arguments: ["-s", serial, "shell"] + args)
            }.value
        }
        _ = try await command(["am", "force-stop", "org.kestrel.diagnostics"])
        _ = try await command(["run-as", "org.kestrel.diagnostics", "rm", "-f", "files/report.json"])
        _ = try await command(["am", "start", "-W", "-n", "org.kestrel.diagnostics/.ProbeActivity",
                               "--ei", "duration_seconds", "60"])
        try await Task.sleep(for: .seconds(2))
        let input = try await command(["dumpsys", "input"])
        guard input.contains("orientation=\(orientation.rawValue), logicalFrame="),
              let view = controller?.player.frameView, let window = controller?.player.window,
              let frame = view.screenshotFrame(), view.displayedRotation == orientation else {
            throw KestrelError.runtime("Touch fixture orientation did not match rendered orientation")
        }
        let focus = try await Task.detached { try Self.focusedWindow(adb: adb, serial: serial) }.value
        guard focus.contains("org.kestrel.diagnostics/") else {
            throw KestrelError.runtime("Touch fixture is not focused")
        }
        let size = orientation.logicalSize(width: frame.width, height: frame.height)
        guard let viewport = PlayerViewport(imageWidth: size.width, imageHeight: size.height,
            surfaceWidth: Double(view.bounds.width), surfaceHeight: Double(view.bounds.height)) else {
            throw KestrelError.runtime("Invalid rotated viewport")
        }
        let expectedX = Int(Double(size.width) * 0.27)
        let expectedY = Int(Double(size.height) * 0.63)
        let x = viewport.x + (Double(expectedX) + 0.5) * viewport.width / Double(size.width)
        let y = viewport.y + (Double(expectedY) + 0.5) * viewport.height / Double(size.height)
        let local = NSPoint(x: view.bounds.minX + x,
            y: view.isFlipped ? view.bounds.minY + y : view.bounds.maxY - y)
        let point = view.convert(local, to: nil)
        @MainActor func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                throw KestrelError.runtime("Could not construct rotated pointer event")
            }
            return event
        }
        view.mouseDown(with: try event(.leftMouseDown))
        try await Task.sleep(for: .milliseconds(100))
        view.mouseUp(with: try event(.leftMouseUp))
        try await Task.sleep(for: .milliseconds(300))
        guard let controller else { throw KestrelError.runtime("Missing replay controller") }
        let keymap = Keymap(name: "Rotated replay", controls: [.tap(TapControl(key: "SPACE",
            at: NPoint(Double(expectedX) / Double(size.width - 1), Double(expectedY) / Double(size.height - 1))))])
        let recording = InputRecording(entries: [.init(t: 0, event: .keyDown("SPACE")),
                                                .init(t: 150, event: .keyUp("SPACE"))])
        var replayResult: Result<Void, Error>?
        try controller.replay(recording, keymap: keymap, sensitivity: 1) { replayResult = $0 }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while replayResult == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let replayResult else { throw KestrelError.runtime("Rotated replay timed out") }
        try replayResult.get()
        _ = try await command(["am", "start", "-W", "-a", "android.settings.SETTINGS"])
        let report = try await command(["run-as", "org.kestrel.diagnostics", "cat", "files/report.json"])
        let object = try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any]
        let touches = object?["touches"] as? [[String: Any]] ?? []
        guard touches.compactMap({ $0["action"] as? Int }) == [0, 1, 0, 1] else {
            throw KestrelError.runtime("Rotated mouse and replay did not produce two down/up pairs")
        }
        for touch in touches {
            guard let rawX = touch["raw_x"] as? Double, let rawY = touch["raw_y"] as? Double else {
                throw KestrelError.runtime("Missing recorded touch coordinates")
            }
            log("TOUCH orientation=\(orientation.rawValue): expected=(\(expectedX),\(expectedY)), guest=(\(rawX),\(rawY))")
            guard abs(rawX - Double(expectedX)) <= 3, abs(rawY - Double(expectedY)) <= 3 else {
                throw KestrelError.runtime("Rotated touch missed expected guest coordinates")
            }
        }
    }

    func inspectRotation() {
        Task { [self] in
            do {
                guard let store else { throw KestrelError.runtime("Missing fixture") }
                let adb = store.sdk.adb
                let serial = Ports.forInstance(0).serial
                func command(_ args: [String]) async throws -> String {
                    try await Task.detached {
                        try Self.captureADB(adb: adb, arguments: ["-s", serial, "shell"] + args)
                    }.value
                }
                var querySeconds: [Double] = []
                for _ in 0..<10 {
                    let began = ProcessInfo.processInfo.systemUptime
                    _ = try await Task.detached {
                        try PlayerRotationControl.inspect(adb: adb, serial: serial)
                    }.value
                    querySeconds.append(ProcessInfo.processInfo.systemUptime - began)
                }
                let sortedQueries = querySeconds.sorted()
                log("ORIENTATION QUERY seconds: min=\(sortedQueries[0]), median=\(sortedQueries[5]), max=\(sortedQueries[9]); command timeout=2s, observer sleep=0.5s. Wall time is not CPU usage.")
                let original = try await command(["wm", "user-rotation"]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard original == "free" else { throw KestrelError.runtime("Rotation fixture must start in free mode") }
                let baseline = try await command(["dumpsys", "input"])
                guard baseline.contains("orientation=0, logicalFrame=[0, 0, 1280, 720]") else {
                    throw KestrelError.runtime("Unexpected baseline input viewport")
                }
                let apk = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".build/diagnostics/kestrel-diagnostics.apk")
                try await Task.detached {
                    try PlayerCommandProcess.run(executable: adb,
                        arguments: ["-s", serial, "uninstall", "org.kestrel.diagnostics"], timeout: 10)
                    try PlayerCommandProcess.run(executable: adb,
                        arguments: ["-s", serial, "install", apk.path], timeout: 20)
                }.value
                var experimentError: Error?
                do {
                    _ = try await command(["am", "start", "-W", "-a", "android.settings.SETTINGS"])
                    for args in [["wm", "fixed-to-user-rotation"], ["wm", "get-ignore-orientation-request"]] {
                        log("POLICY \(args.joined(separator: " ")): \(try await command(args))")
                    }
                    guard let player = controller?.player else { throw KestrelError.runtime("Missing player") }
                    guard player.supportedActions.contains(.rotate) else {
                        throw KestrelError.runtime("Production Rotate action is not enabled")
                    }
                    for rotation in [1, 2, 3, 0] {
                        guard player.perform(.rotate) else { throw KestrelError.runtime("Rotate action was not accepted") }
                        let commandDeadline = ContinuousClock.now.advanced(by: .seconds(15))
                        while player.commandBusy && ContinuousClock.now < commandDeadline {
                            try await Task.sleep(for: .milliseconds(50))
                        }
                        guard !player.commandBusy, player.isConnected, !inputErrorReported else {
                            throw KestrelError.runtime("Rotate action failed or timed out")
                        }
                        try await Task.sleep(for: .milliseconds(300))
                        let input = try await command(["dumpsys", "input"])
                        let state = try await command(["wm", "user-rotation"])
                        log("ROTATION \(rotation): \(state.trimmingCharacters(in: .whitespacesAndNewlines))")
                        for line in Set(input.components(separatedBy: .newlines).filter {
                            $0.contains("Viewport INTERNAL: displayId=0")
                        }).sorted() { print(line) }
                        guard input.contains("orientation=\(rotation), logicalFrame="),
                              let view = controller?.player.frameView,
                              let orientation = PlayerRotation(rawValue: rotation) else {
                            throw KestrelError.runtime("Requested rotation was not observed in guest input viewport")
                        }
                        let redrawDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                        while view.displayedRotation != orientation && ContinuousClock.now < redrawDeadline {
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        guard view.displayedRotation == orientation, let frame = view.screenshotFrame() else {
                            throw KestrelError.runtime("No corrected frame during rotation")
                        }
                        log("VIDEO: \(frame.width)x\(frame.height), sensorRotation=\(String(describing: frame.sensorRotation?.rawValue)), timestamp=\(frame.timestampMicroseconds)")
                        let captures = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-rotation-captures")
                        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
                        try PlayerFramePNG.write(frame, to: captures.appendingPathComponent("stream-\(rotation).png"))
                        try PlayerFramePNG.write(frame, to: captures.appendingPathComponent("upright-\(rotation).png"), rotation: orientation)
                        _ = try await command(["screencap", "-p", "/data/local/tmp/kestrel-rotation.png"])
                        let destination = captures.appendingPathComponent("android-\(rotation).png")
                        try await Task.detached {
                            try PlayerCommandProcess.run(executable: adb,
                                arguments: ["-s", serial, "pull", "/data/local/tmp/kestrel-rotation.png", destination.path], timeout: 5)
                        }.value
                        _ = try await command(["rm", "/data/local/tmp/kestrel-rotation.png"])
                        let policy = try await command(["dumpsys", "window", "displays"])
                        for line in policy.components(separatedBy: .newlines)
                            where line.contains("mCurrentAppOrientation") || line.contains("mRotation=") || line.contains("mFixedToUserRotation") {
                            print("DISPLAY POLICY: \(line)")
                        }
                        try await verifyRotatedTouch(orientation, adb: adb, serial: serial)
                        if rotation == 1 {
                            _ = try await command(["input", "keyevent", "3"])
                            try await Task.sleep(for: .seconds(1))
                            let home = try PlayerDisplayOrientation.parse(await command(["dumpsys", "input"]))
                            let homeDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                            while view.displayedRotation != home.rotation && ContinuousClock.now < homeDeadline {
                                try await Task.sleep(for: .milliseconds(20))
                            }
                            guard home.rotation == .natural, view.displayedRotation == home.rotation else {
                                throw KestrelError.runtime("Player did not follow Home orientation")
                            }
                            log("APP SWITCH Home verified: viewport=\(home.rotation.rawValue), player=\(view.displayedRotation.rawValue)")
                            _ = try await command(["am", "start", "-W", "-a", "android.settings.SETTINGS"])
                            try await Task.sleep(for: .seconds(1))
                            let settings = try PlayerDisplayOrientation.parse(await command(["dumpsys", "input"]))
                            let settingsDeadline = ContinuousClock.now.advanced(by: .seconds(3))
                            while view.displayedRotation != settings.rotation && ContinuousClock.now < settingsDeadline {
                                try await Task.sleep(for: .milliseconds(20))
                            }
                            guard settings.rotation == .quarter, view.displayedRotation == settings.rotation else {
                                throw KestrelError.runtime("Player did not follow Settings orientation")
                            }
                            log("APP SWITCH Settings verified: viewport=\(settings.rotation.rawValue), player=\(view.displayedRotation.rawValue)")
                        }
                    }
                } catch { experimentError = error }
                _ = try await command(["wm", "user-rotation", "lock", "0"])
                try await Task.sleep(for: .seconds(2))
                _ = try await command(["wm", "user-rotation", "free"])
                try await Task.sleep(for: .seconds(2))
                _ = try await command(["sync"])
                let restored = try await command(["wm", "user-rotation"]).trimmingCharacters(in: .whitespacesAndNewlines)
                let restoredInput = try await command(["dumpsys", "input"])
                guard restored == original, restoredInput.contains("orientation=0, logicalFrame=[0, 0, 1280, 720]") else {
                    throw KestrelError.runtime("Rotation restoration did not match baseline")
                }
                log("RESTORED: free rotation, orientation 0, 1280x720 viewport")
                if let experimentError { throw experimentError }
                passed = true
                controller?.stop()
            } catch {
                log("Rotation inspection failed: \(error)")
                controller?.stop()
            }
        }
    }

    func ready() {
        if rotationInspectMode { inspectRotation(); return }
        if inputFailureMode { injectInputFailure(); return }
        log("[1/4] Ready after \(Date().timeIntervalSince(began))s; [2/4] checking stream renewal")
        Task { [self] in
            do {
                guard let store else { throw KestrelError.runtime("Missing diagnostic store") }
                let adb = store.sdk.adb
                let serial = Ports.forInstance(0).serial
                try await Task.detached {
                    try PlayerCommandProcess.run(executable: adb,
                        arguments: ["-s", serial, "shell", "am", "start", "-W", "-a", "android.settings.SETTINGS"], timeout: 5)
                    guard try Self.focusedWindow(adb: adb, serial: serial).contains("com.android.settings/") else {
                        throw KestrelError.runtime("Settings did not receive focus")
                    }
                }.value
                guard controller?.player.perform(.home) == true else {
                    throw KestrelError.runtime("Native Home control was not accepted")
                }
                try await Task.sleep(for: .seconds(2))
                try await Task.detached {
                    guard try Self.focusedWindow(adb: adb, serial: serial).contains("com.google.android.apps.nexuslauncher/") else {
                        throw KestrelError.runtime("Home did not focus Android launcher")
                    }
                }.value
                log("[2/4] Native Home moved guest focus from Settings to Android launcher")
                try await Task.detached {
                    try PlayerCommandProcess.run(executable: adb, arguments: ["-s", serial, "shell", "am", "force-stop", "org.kestrel.diagnostics"], timeout: 5)
                    try PlayerCommandProcess.run(executable: adb, arguments: ["-s", serial, "shell", "run-as", "org.kestrel.diagnostics", "rm", "-f", "files/report.json"], timeout: 5)
                    try PlayerCommandProcess.run(executable: adb, arguments: ["-s", serial, "shell", "am", "start", "-W", "-n", "org.kestrel.diagnostics/.ProbeActivity", "--ei", "duration_seconds", "60"], timeout: 5)
                }.value
                try await Task.sleep(for: .seconds(3))
                guard try await Task.detached(operation: {
                    try Self.focusedWindow(adb: adb, serial: serial).contains("org.kestrel.diagnostics/")
                }).value, let view = controller?.player.frameView, let window = controller?.player.window else {
                    throw KestrelError.runtime("Diagnostic did not receive focus")
                }
                let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                @MainActor func event(_ type: NSEvent.EventType) throws -> NSEvent {
                    guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                        throw KestrelError.runtime("Could not construct test mouse event")
                    }
                    return event
                }
                guard let controller else { throw KestrelError.runtime("Missing player controller") }
                let lease = try controller.acquireKeymapInput()
                do {
                    _ = try controller.acquireKeymapInput()
                    throw KestrelError.runtime("Duplicate keymap lease accepted")
                } catch KestrelError.runtime(let message) where message == "Player input is unavailable or already leased" { }
                try lease.send([.down(slot: 0, x: 640, y: 360)])
                // Direct mouse input must be suppressed while the keymap owns the slot.
                view.mouseDown(with: try event(.leftMouseDown))
                view.mouseUp(with: try event(.leftMouseUp))
                try await Task.sleep(for: .milliseconds(150))
                controller.releaseKeymapInput()
                do {
                    try lease.send([.down(slot: 0, x: 1, y: 1)])
                    throw KestrelError.runtime("Stale keymap lease accepted input")
                } catch KestrelError.runtime(let message) where message == "Keymap input lease is closed" { }
                let keymap = Keymap(name: "Replay diagnostic", controls: [.tap(TapControl(key: "SPACE", at: NPoint(0.5, 0.5)))])
                let recording = InputRecording(entries: [.init(t: 0, event: .keyDown("SPACE")),
                                                        .init(t: 150, event: .keyUp("SPACE"))])
                var replayResult: Result<Void, Error>?
                try controller.replay(recording, keymap: keymap, sensitivity: 1) { replayResult = $0 }
                let replayDeadline = ContinuousClock.now.advanced(by: .seconds(5))
                while replayResult == nil && ContinuousClock.now < replayDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard let replayResult else { throw KestrelError.runtime("Replay completion timed out") }
                try replayResult.get()
                view.mouseDown(with: try event(.leftMouseDown))
                try await Task.sleep(for: .milliseconds(100))
                view.mouseUp(with: try event(.leftMouseUp))
                try await Task.sleep(for: .milliseconds(500))
                guard controller.player.perform(.home) else {
                    throw KestrelError.runtime("Home after tap was not accepted")
                }
                try await Task.sleep(for: .seconds(1))
                let report = try await Task.detached {
                    try Self.captureADB(adb: adb, arguments: ["-s", serial, "shell", "run-as", "org.kestrel.diagnostics", "cat", "files/report.json"])
                }.value
                let object = try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any]
                let events = object?["touches"] as? [[String: Any]] ?? []
                guard events.compactMap({ $0["action"] as? Int }) == [0, 1, 0, 1, 0, 1],
                      events.allSatisfy({ $0["pointer_count"] as? Int == 1 }) else {
                    throw KestrelError.runtime("Guest did not record keymap release followed by mouse tap")
                }
                log("[2/4] Guest verified keymap lease, recorded key replay and mouse tap; three ordered down/up pairs")
            } catch {
                log("[2/4] Home verification failed: \(type(of: error))")
                controller?.stop()
                return
            }
            try? await Task.sleep(for: .seconds(25))
            guard let first = controller?.player.frameView.screenshotFrame() else {
                controller?.stop(); return
            }
            try? await Task.sleep(for: .seconds(7))
            guard let second = controller?.player.frameView.screenshotFrame(),
                  second.timestampMicroseconds > first.timestampMicroseconds,
                  controller?.player.isConnected == true else {
                controller?.stop(); return
            }
            do {
                guard let controller else { throw KestrelError.runtime("Missing player") }
                let keymap = Keymap(name: "Cancel replay", controls: [.tap(TapControl(key: "SPACE", at: NPoint(0.5, 0.5)))])
                let recording = InputRecording(entries: [.init(t: 0, event: .keyDown("SPACE")),
                                                        .init(t: 60_000, event: .keyUp("SPACE"))])
                try controller.replay(recording, keymap: keymap, sensitivity: 1) { [weak self] result in
                    if case .failure(let error) = result, error is CancellationError {
                        self?.replayCancelled = true
                    }
                }
                try await Task.sleep(for: .milliseconds(200))
                passed = true
                closeStarted = Date()
                log("[2/4] Stream renewed; [3/4] closing during a 60-second recording pause")
                controller.player.close()
            } catch {
                log("[3/4] Replay cancellation setup failed")
                controller?.stop()
            }
        }
    }

    func stopped(_ result: Result<Void, Error>) {
        heartbeat?.invalidate()
        let stopped = store.map { Launcher(store: $0).runningPID(0) == nil } ?? false
        if rotationInspectMode {
            guard passed, stopped, case .success = result else { exit(1) }
            log("SUMMARY: read-only rotation inspection completed; VM stopped")
            exit(0)
        }
        if inputFailureMode {
            guard inputFailureInjected, inputErrorReported, !timedOut, stopped,
                  let closeStarted, Date().timeIntervalSince(closeStarted) < 20,
                  case .failure = result else {
                log("[4/4] FAILED: asynchronous input failure was not reported and cleaned up")
                exit(1)
            }
            log("[4/4] SUMMARY: asynchronous touch failure reported; owned VM stopped automatically")
            exit(0)
        }
        guard passed, !timedOut, stopped, replayCancelled,
              let closeStarted, Date().timeIntervalSince(closeStarted) < 20,
              case .success = result else {
            log("[4/4] FAILED: renewal/cleanup check; VM stopped=\(stopped)")
            exit(1)
        }
        log("[3/4] Owned VM stopped; [4/4] SUMMARY: window, renewal and close cleanup passed")
        exit(0)
    }
}

@main
struct NativeSessionWindowProbe {
    static func main() {
        guard #available(macOS 15, *) else { exit(2) }
        let app = NSApplication.shared
        let delegate = WindowProbe()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
