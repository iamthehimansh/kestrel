// Exercises the actual KestrelCore Launcher, not the Python experimental argument builder.
// Control input/output must be pipes; configuration and public policies contain no secrets.
import Darwin
import Foundation
import KestrelCore

@main
struct ProductLauncherProbe {
    static func reply(_ value: [String: Any]) throws {
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(bytes)
        FileHandle.standardOutput.write(Data([10]))
    }

    static func socketEvidence(pid: Int32) throws -> String {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-sockets-\(UUID()).txt")
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw KestrelError.runtime("Could not create diagnostic socket output")
        }
        defer { try? FileManager.default.removeItem(at: output) }
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", "\(pid)", "-iTCP:8556", "-sTCP:LISTEN", "-FpnT"]
        process.standardOutput = file
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        if ended.wait(timeout: .now() + 3) == .timedOut {
            if process.isRunning { process.terminate() }
            if ended.wait(timeout: .now() + 1) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = ended.wait(timeout: .now() + 1)
            }
            throw KestrelError.runtime("Socket evidence collection timed out")
        }
        guard process.terminationStatus == 0 else { throw KestrelError.runtime("No listener found for owned PID") }
        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let bytes = try reader.read(upToCount: 65_537) ?? Data()
        guard bytes.count <= 65_536, let text = String(data: bytes, encoding: .utf8) else {
            throw KestrelError.runtime("Invalid socket evidence")
        }
        return text
    }

    static func main() {
        guard CommandLine.arguments.count == 4, isatty(STDIN_FILENO) == 0,
              isatty(STDOUT_FILENO) == 0 else {
            fputs("Expected three arguments and private controller pipes\n", stderr); exit(2)
        }
        guard let resolved = realpath(CommandLine.arguments[1], nil) else {
            fputs("Diagnostic profile does not resolve\n", stderr); exit(2)
        }
        let canonical = String(cString: resolved)
        free(resolved)
        let components = canonical.split(separator: "/")
        guard components.count == 3, components[0] == "private", components[1] == "tmp",
              components[2].hasPrefix("kestrel-perf-") else {
            fputs("Profile is not a direct disposable test directory\n", stderr); exit(2)
        }
        let home = URL(fileURLWithPath: canonical)
        let sdk = AndroidSDK(root: URL(fileURLWithPath: CommandLine.arguments[2]))
        let policy = URL(fileURLWithPath: CommandLine.arguments[3])
        let store = InstanceStore(paths: KestrelPaths(root: home), sdk: sdk)
        let launcher = Launcher(store: store)
        var ownedProcess: OwnedEmulatorProcess?
        var success = false
        var stage = "profile_validation"
        do {
            let instance = try store.load(0)
            guard instance.settings.name == "Startup probe", launcher.runningPID(0) == nil else {
                throw KestrelError.invalid("Not an idle diagnostic instance")
            }
            // Use the shipping signer's canonical read-only policy, not Python reserialization.
            stage = "policy_write"
            try EmulatorTokenSigner.accessPolicy().write(to: policy, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: policy.path)
            let player = try EmulatorPlayerLaunch(port: 8556, policyFile: policy)
            stage = "start"
            let process = try launcher.startOwned(0, coldBoot: true, player: player)
            ownedProcess = process
            let pid = process.processIdentifier
            stage = "boot_readiness"
            try launcher.waitForBoot(0, process: process, timeout: 180)
            stage = "endpoint_validation"
            let reader = try FileHandle(forReadingFrom: launcher.logFile(0))
            defer { try? reader.close() }
            let logBytes = try reader.read(upToCount: 1_048_577) ?? Data()
            guard logBytes.count <= 1_048_576, let log = String(data: logBytes, encoding: .utf8) else {
                throw KestrelError.runtime("Invalid bounded startup log")
            }
            let sockets = try socketEvidence(pid: pid)
            let discoveryRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
            let evidence = try EmulatorEndpointDiscovery.inspect(process: process, port: player.port,
                logFile: launcher.logFile(0), discoveryRoot: discoveryRoot)
            let independent = try EmulatorEndpointEvidence.parse(log: log, sockets: sockets,
                pid: pid, port: player.port, discoveryRoot: discoveryRoot)
            guard independent.publicKeyDirectory == evidence.publicKeyDirectory,
                  independent.host == evidence.host, independent.port == evidence.port else {
                throw KestrelError.runtime("Endpoint discovery disagrees with diagnostic evidence")
            }
            guard process.isRunning else { throw KestrelError.runtime("Process exited during endpoint check") }
            try sockets.write(to: policy.deletingLastPathComponent().appendingPathComponent("native-socket-evidence.txt"),
                              atomically: true, encoding: .utf8)
            try reply(["status": "ready", "pid": pid, "log": launcher.logFile(0).path,
                       "player_policy_validated": true, "endpoint_validated": true,
                       "host": evidence.host, "port": evidence.port,
                       "public_key_directory": evidence.publicKeyDirectory.path])
            // EOF also means the controlling diagnostic ended: don't leave its VM running.
            let instruction = readLine()
            guard instruction == nil || instruction == "stop" else {
                throw KestrelError.invalid("Unsupported diagnostic command")
            }
            success = true
        } catch {
            var result: [String: Any] = ["status": "failed", "stage": stage,
                                         "error_type": String(describing: type(of: error))]
            if let local = error as? KestrelError { result["local_error"] = local.description }
            try? reply(result)
        }
        if let process = ownedProcess {
            do {
                try process.stop {
                    try PlayerCommandProcess.run(executable: sdk.adb,
                        arguments: ["-s", Ports.forInstance(0).serial, "emu", "kill"], timeout: 5)
                }
                guard !process.isRunning else { throw KestrelError.runtime("Diagnostic still running") }
                try reply(["status": "stopped", "pid": process.processIdentifier, "retained_child_stopped": true])
            } catch {
                success = false
                try? reply(["status": "cleanup_failed", "error_type": String(describing: type(of: error))])
            }
        }
        exit(success ? 0 : 1)
    }
}
