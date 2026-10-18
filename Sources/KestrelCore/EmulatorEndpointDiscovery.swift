import Darwin
import Foundation

public enum EmulatorEndpointDiscovery {
    /// Evidence is sampled while the retained child is alive. This does not authenticate
    /// arbitrary PID files or defend against a malicious process running as the same user.
    public static func inspect(process: OwnedEmulatorProcess, port: Int, logFile: URL,
                               discoveryRoot: URL) throws -> EmulatorEndpointEvidence {
        guard process.isRunning, (1024...65535).contains(port), logFile.isFileURL else {
            throw KestrelError.invalid("Invalid owned emulator endpoint request")
        }
        let log = try readBounded(logFile, limit: 1_048_576)
        let sockets = try socketEvidence(pid: process.processIdentifier, port: port)
        let evidence = try EmulatorEndpointEvidence.parse(log: log, sockets: sockets,
            pid: process.processIdentifier, port: port, discoveryRoot: discoveryRoot)
        guard process.isRunning else { throw KestrelError.runtime("Emulator exited during endpoint discovery") }
        return evidence
    }

    private static func socketEvidence(pid: Int32, port: Int) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-endpoint-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("sockets.txt")
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw KestrelError.runtime("Could not create socket evidence output")
        }
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        child.arguments = ["-nP", "-a", "-p", "\(pid)", "-iTCP:\(port)", "-sTCP:LISTEN", "-FpnT"]
        child.standardOutput = file
        child.standardError = FileHandle.nullDevice
        child.standardInput = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in ended.signal() }
        try child.run()
        if ended.wait(timeout: .now() + 3) == .timedOut {
            try OwnedEmulatorProcess(process: child, pidFile: directory.appendingPathComponent("unused.pid"))
                .stop(gracePeriod: 0)
            throw KestrelError.runtime("Socket evidence collection timed out")
        }
        guard child.terminationStatus == 0 else {
            throw KestrelError.runtime("No listener found for owned emulator")
        }
        return try readBounded(output, limit: 65_536)
    }

    private static func readBounded(_ url: URL, limit: Int) throws -> String {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let bytes = try reader.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit, let text = String(data: bytes, encoding: .utf8) else {
            throw KestrelError.runtime("Invalid bounded endpoint evidence")
        }
        return text
    }
}
