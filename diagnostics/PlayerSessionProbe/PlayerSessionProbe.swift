import Darwin
import Foundation
import KestrelCore
import KestrelStream

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}

@main
struct PlayerSessionProbe {
    static func log(_ step: Int, _ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        print("[\(formatter.string(from: Date()))] [\(step)/4] \(message)")
        fflush(stdout)
    }

    @available(macOS 15, *)
    static func run() async throws {
        let cancelStartup = CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "--cancel-start"
        let keyboardTest = CommandLine.arguments.count == 4 && CommandLine.arguments[3] == "--keyboard"
        guard CommandLine.arguments.count == 3 || cancelStartup || keyboardTest,
              let resolved = realpath(CommandLine.arguments[1], nil) else {
            throw KestrelError.invalid("Expected disposable profile and SDK paths")
        }
        let canonical = String(cString: resolved)
        free(resolved)
        let parts = canonical.split(separator: "/")
        guard parts.count == 3, parts[0] == "private", parts[1] == "tmp",
              parts[2].hasPrefix("kestrel-perf-") else {
            throw KestrelError.invalid("Not a direct disposable profile directory")
        }
        let store = InstanceStore(paths: KestrelPaths(root: URL(fileURLWithPath: canonical)),
            sdk: AndroidSDK(root: URL(fileURLWithPath: CommandLine.arguments[2])))
        let launcher = Launcher(store: store)
        let isolated = ProcessInfo.processInfo.environment["KESTREL_PROBE_ISOLATED"] == "1"
        let index = isolated ? 49 : 0
        if isolated {
            guard ProcessInfo.processInfo.environment["ANDROID_ADB_SERVER_PORT"] == "15037",
                  ProcessInfo.processInfo.environment["ADB_SERVER_SOCKET"] == "tcp:127.0.0.1:15037" else {
                throw KestrelError.invalid("Isolated probe requires private ADB endpoint")
            }
        }
        guard try store.load(index).settings.name == "Startup probe", launcher.runningPID(index) == nil else {
            throw KestrelError.invalid("Diagnostic profile is not idle")
        }
        let session = EmulatorPlayerSession(store: store, index: index, port: isolated ? 18556 : 8556)
        if cancelStartup {
            log(1, "Starting VM; cancellation will be requested after one second")
            let observed = Counter()
            let pidFile = store.paths.instanceDir(index).appendingPathComponent("emulator.pid")
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if let text = try? String(contentsOf: pidFile, encoding: .utf8),
                   let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
                   pid > 0, kill(pid, 0) == 0 { _ = observed.next() }
                session.requestCancellation()
            }
            let began = Date()
            do {
                _ = try session.start(coldBoot: true)
                throw KestrelError.runtime("Startup completed instead of being cancelled")
            } catch is CancellationError {
                guard observed.next() == 2 else {
                    try session.close()
                    throw KestrelError.runtime("Cancellation did not target a live startup")
                }
                try session.close()
                guard launcher.runningPID(index) == nil, Date().timeIntervalSince(began) < 30 else {
                    throw KestrelError.runtime("Cancelled startup cleanup exceeded budget or left VM running")
                }
                log(4, "SUMMARY: cancelled a live startup; owned VM stopped in \(Date().timeIntervalSince(began))s")
                return
            } catch {
                try session.close()
                throw error
            }
        }
        do {
            log(1, "Launching app-owned authenticated session")
            let began = Date()
            let endpoint = try session.start(coldBoot: true)
            log(1, "Ready after \(Date().timeIntervalSince(began))s")
            let client = EmulatorFrameClient(endpoint: try EmulatorFrameEndpoint(host: endpoint.host, port: endpoint.port))
            let request = try EmulatorFrameRequest(width: 1280, height: 720, seconds: 10)
            log(2, "Checking authenticated screenshot and bounded stream")
            var frame: PlayerFrame?
            for attempt in 0..<20 {
                do {
                    frame = try await client.screenshot(request, credential: session.token(for: .getScreenshot))
                    break
                } catch EmulatorFrameConnectionError.rejected {
                    if attempt == 19 { throw EmulatorFrameConnectionError.rejected }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            guard frame?.width == 1280, frame?.height == 720 else {
                throw KestrelError.runtime("Expected complete 720p frame")
            }
            let counter = Counter()
            let frames = try await client.stream(request, credential: session.token(for: .streamScreenshot)) { _ in
                counter.next() < 30
            }
            guard frames == 30 else { throw KestrelError.runtime("Unexpected bounded frame count") }
            log(2, "Screenshot and 30 frames received")
            if keyboardTest {
                let adb = store.sdk.adb
                let serial = Ports.forInstance(index).serial
                let apk = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent(".build/diagnostics/kestrel-diagnostics.apk")
                func setup(_ stage: String, _ arguments: [String], timeout: TimeInterval) throws {
                    log(2, "Fixture setup: \(stage)")
                    do {
                        let output = try PlayerCommandCapture.run(executable: adb,
                            arguments: ["-s", serial] + arguments, timeout: timeout, maximumBytes: 8192)
                        log(2, "Fixture setup \(stage) completed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                    } catch {
                        log(2, "Fixture setup \(stage) failed: \(error)")
                        throw error
                    }
                }
                let installed = try PlayerCommandCapture.run(executable: adb,
                    arguments: ["-s", serial, "shell", "pm", "list", "packages", "org.kestrel.diagnostics"], timeout: 5)
                if installed.components(separatedBy: .newlines).contains("package:org.kestrel.diagnostics") {
                    try setup("remove old test signing identity", ["uninstall", "org.kestrel.diagnostics"], timeout: 10)
                }
                try setup("install", ["install", apk.path], timeout: 20)
                try setup("clear test app", ["shell", "pm", "clear", "org.kestrel.diagnostics"], timeout: 5)
                try setup("launch field", ["shell", "am", "start", "-W", "-n",
                    "org.kestrel.diagnostics/.KeyboardActivity"], timeout: 5)
                try await Task.sleep(for: .seconds(1))
                func focusEvidence() throws -> PlayerGuestTextFocus? {
                    let began = ProcessInfo.processInfo.systemUptime
                    log(2, "Inspect current editor (bounded input_method query)")
                    let output: String
                    do {
                        output = try PlayerCommandCapture.run(executable: adb,
                            arguments: ["-s", serial, "shell", "dumpsys", "input_method"], timeout: 3)
                    } catch {
                        log(2, "Editor inspection failed after \(ProcessInfo.processInfo.systemUptime - began)s: \(error)")
                        return nil
                    }
                    let parsed = PlayerGuestTextFocus.parse(output)
                    // Also require the production observer's before/after window validation
                    // and 500ms budget. Parser-only success is not production typing proof.
                    let validated = try PlayerGuestTextObserver.inspect(adb: adb, serial: serial)
                    guard parsed == validated else {
                        throw KestrelError.runtime("Production observer did not confirm the parsed editor")
                    }
                    let clientCount = output.components(separatedBy: .newlines).filter {
                        $0.hasPrefix("Input method client state for ")
                    }.count
                    log(2, "Focus parser: clients=\(clientCount), activeEditor=\(parsed != nil), fixturePackage=\(parsed?.packageName == "org.kestrel.diagnostics")")
                    return parsed
                }
                let initialFocus = try focusEvidence()
                func reportStage(_ stage: String) async throws {
                    try await Task.sleep(for: .milliseconds(300))
                    let data = try PlayerCommandCapture.run(executable: adb, arguments: ["-s", serial, "shell", "run-as",
                        "org.kestrel.diagnostics", "cat", "files/keyboard-report.json"], timeout: 3, maximumBytes: 4096)
                    let report = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] ?? [:]
                    log(2, "Keyboard stage \(stage): length=\(report["length"] ?? "missing"), focused=\(report["focused"] ?? "missing"), matches=\(report["matches_expected"] ?? "missing"), prefix=\(report["matches_prefix"] ?? "missing"), beforeDelete=\(report["matches_before_delete"] ?? "missing"), caseInsensitive=\(report["matches_expected_case_insensitive"] ?? "missing")")
                }
                try await reportStage("before")
                guard initialFocus?.packageName == "org.kestrel.diagnostics" else {
                    throw KestrelError.runtime("Test editor is not confirmed active; no text sent")
                }
                let readiness = try PlayerCommandCapture.run(executable: adb, arguments: ["-s", serial, "shell", "run-as",
                    "org.kestrel.diagnostics", "cat", "files/keyboard-report.json"], timeout: 3, maximumBytes: 4096)
                let ready = try JSONSerialization.jsonObject(with: Data(readiness.utf8)) as? [String: Any]
                guard ready?["has_window_focus"] as? Bool == true, ready?["focused"] as? Bool == true else {
                    throw KestrelError.runtime("Test field lacks window focus; no text sent")
                }
                // Exercise the shipping transport's ordered per-character expansion,
                // not a separate diagnostic-only loop that could hide bulk text loss.
                try await client.sendKey(EmulatorKeyboardRequest(text: "Kestrel keyboard 4"),
                                         credential: session.token(for: .sendKey))
                try await reportStage("prefix")
                try await client.sendKey(EmulatorKeyboardRequest(text: "3"), credential: session.token(for: .sendKey))
                try await reportStage("append")
                try await client.sendKey(EmulatorKeyboardRequest(key: .backspace), credential: session.token(for: .sendKey))
                try await reportStage("backspace")
                try await client.sendKey(EmulatorKeyboardRequest(text: "2"), credential: session.token(for: .sendKey))
                try await reportStage("final")
                try await Task.sleep(for: .milliseconds(500))
                let report = try PlayerCommandCapture.run(executable: adb, arguments: ["-s", serial, "shell", "run-as",
                    "org.kestrel.diagnostics", "cat", "files/keyboard-report.json"], timeout: 3, maximumBytes: 4096)
                let result = try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any]
                guard result?["matches_expected"] as? Bool == true, result?["focused"] as? Bool == true else {
                    throw KestrelError.runtime("Keyboard fixture did not match expected phrase")
                }
                log(2, "Authenticated text and Backspace verified by test-owned field; no entered text logged")
                try PlayerCommandProcess.run(executable: adb, arguments: ["-s", serial, "shell", "input", "keyevent", "3"], timeout: 3)
                try await Task.sleep(for: .milliseconds(500))
                let afterHomeFocus = try focusEvidence()
                guard initialFocus?.packageName == "org.kestrel.diagnostics", afterHomeFocus == nil else {
                    throw KestrelError.runtime("Guest focus parser did not distinguish the fixture from Home")
                }
            }
            log(3, "Closing session and checking process/key cleanup")
            try session.close()
            try session.close()
            guard launcher.runningPID(index) == nil else { throw KestrelError.runtime("Emulator remains running") }
            if FileManager.default.fileExists(atPath: endpoint.publicKeyDirectory.path) {
                let names = try FileManager.default.contentsOfDirectory(atPath: endpoint.publicKeyDirectory.path)
                guard !names.contains(where: { $0.hasPrefix("kestrel-") && $0.hasSuffix(".jwk") }) else {
                    throw KestrelError.runtime("Session public key remains")
                }
            }
            do {
                _ = try session.token(for: .getScreenshot)
                throw KestrelError.runtime("Closed session issued credential")
            } catch is CancellationError { }
            log(3, "Owned emulator stopped; public key removed; further credentials rejected")
            log(4, "SUMMARY: combined session lifecycle passed")
        } catch {
            try session.close()
            throw error
        }
    }

    static func main() async {
        guard #available(macOS 15, *) else { exit(2) }
        do { try await run() }
        catch {
            log(4, "FAILED: \(type(of: error)); no credential values logged")
            exit(1)
        }
    }
}
