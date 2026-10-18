import Darwin
import Foundation
import KestrelCore
import KestrelKeymap

/// Anything that accepts touch ops (the device, or stdout for dry runs).
public protocol TouchSink: AnyObject {
    func send(_ ops: [TouchOp]) throws
    func close()
}

enum TouchHandshake {
    static func read(from handle: FileHandle, timeout: TimeInterval = 10) throws -> String {
        guard timeout.isFinite, timeout > 0, timeout <= 10 else {
            throw KestrelError.invalid("Invalid touch handshake timeout")
        }
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw KestrelError.runtime("Could not configure touch handshake pipe")
        }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var bytes = Data()
        while bytes.count < 4096 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw KestrelError.runtime("Touch handshake timed out") }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, Int32(max(1, min(100, remaining * 1000))))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw KestrelError.runtime("Touch handshake poll failed") }
            if result == 0 { continue }
            var buffer = [UInt8](repeating: 0, count: 4096 - bytes.count)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { throw KestrelError.runtime("Touch helper closed before readiness") }
            bytes.append(contentsOf: buffer.prefix(count))
            if let end = bytes.firstIndex(of: 10) {
                guard let line = String(data: bytes.prefix(upTo: end), encoding: .utf8),
                      line.hasPrefix("ready ") else {
                    throw KestrelError.runtime("Invalid touch helper readiness")
                }
                return line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        throw KestrelError.runtime("Touch helper readiness exceeds size limit")
    }
}

/// Prints ops instead of injecting them.
public final class PrintSink: TouchSink {
    public init() {}
    public func send(_ ops: [TouchOp]) throws { for op in ops { print(op.description) } }
    public func close() {}
}

/// Streams ops to `touchd` running on the device over one persistent `adb shell`, so each
/// event costs one pipe write instead of an adb round trip.
public final class DeviceSink: TouchSink {
    public static let remotePath = "/data/local/tmp/sec_touchd"

    private let process: Process
    private let writer: BoundedTouchWriter
    public let readyLine: String

    /// Locates the touchd binary: KESTREL_TOUCHD, next to the kestrel executable, or the build tree.
    public static func localBinary() throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["KESTREL_TOUCHD"] { candidates.append(URL(fileURLWithPath: env)) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(exe.appendingPathComponent("touchd"))
        candidates.append(exe.appendingPathComponent("../Resources/touchd").standardized)
        // The CLI bundled inside the app: Contents/Resources/bin/kestrel.
        candidates.append(exe.appendingPathComponent("../touchd").standardized)
        candidates.append(exe.appendingPathComponent("../Resources/touchd").standardized)
        candidates.append(exe.appendingPathComponent("../touchd/touchd").standardized)
        candidates.append(exe.appendingPathComponent("../../touchd/touchd").standardized)
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/touchd/touchd"))
        if let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) { return found }
        throw KestrelError.environment("touchd binary not found; build it with ./touchd/build.sh (needs the Android NDK)")
    }

    public init(adb: ADB, width: Int, height: Int) throws {
        let local = try Self.localBinary()
        try PlayerCommandProcess.run(executable: adb.sdk.adb,
            arguments: ["-s", adb.serial, "push", local.path, Self.remotePath], timeout: 15)
        try PlayerCommandProcess.run(executable: adb.sdk.adb,
            arguments: ["-s", adb.serial, "shell", "chmod", "755", Self.remotePath], timeout: 5)

        let p = Process()
        p.executableURL = adb.sdk.adb
        p.arguments = ["-s", adb.serial, "shell", "\(Self.remotePath) \(width) \(height)"]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        let boundedWriter = try BoundedTouchWriter(handle: inPipe.fileHandleForWriting)
        do { try p.run() }
        catch { boundedWriter.close(); throw error }
        process = p
        writer = boundedWriter

        do {
            readyLine = try TouchHandshake.read(from: outPipe.fileHandleForReading)
        } catch {
            boundedWriter.close()
            Self.stopChild(p)
            throw error
        }
        // Keep draining stderr so the pipe never fills and blocks touchd.
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { FileHandle.standardError.write(d) }
        }
        outPipe.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
    }

    public func send(_ ops: [TouchOp]) throws {
        guard !ops.isEmpty else { return }
        guard process.isRunning else { throw KestrelError.runtime("touchd exited") }
        let text = ops.map(\.description).joined(separator: "\n") + "\n"
        do { try writer.write(Data(text.utf8)) }
        catch {
            writer.close()
            if process.isRunning { process.terminate() }
            throw error
        }
    }

    public func close() {
        try? writer.write(Data("reset\n".utf8))
        writer.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
        Self.stopChild(process)
    }

    private static func stopChild(_ process: Process) {
        if process.isRunning { process.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(20_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
