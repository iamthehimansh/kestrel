import Foundation
import KestrelCore
import KestrelKeymap

/// Anything that accepts touch ops (the device, or stdout for dry runs).
public protocol TouchSink: AnyObject {
    func send(_ ops: [TouchOp]) throws
    func close()
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func set(_ v: String) { lock.lock(); value = v; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
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
    public static let remotePath = "/data/local/tmp/kestrel-touchd"

    private let process: Process
    private let stdin: FileHandle
    public let readyLine: String

    /// Locates the touchd binary: KESTREL_TOUCHD, next to the kestrel executable, or the build tree.
    public static func localBinary() throws -> URL {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["KESTREL_TOUCHD"] { candidates.append(URL(fileURLWithPath: env)) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(exe.appendingPathComponent("touchd"))
        candidates.append(exe.appendingPathComponent("../Resources/touchd").standardized)
        candidates.append(exe.appendingPathComponent("../touchd/touchd").standardized)
        candidates.append(exe.appendingPathComponent("../../touchd/touchd").standardized)
        candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".build/touchd/touchd"))
        if let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) { return found }
        throw KestrelError.environment("touchd binary not found; build it with ./touchd/build.sh (needs the Android NDK)")
    }

    public init(adb: ADB, width: Int, height: Int) throws {
        let local = try Self.localBinary()
        try adb.run(["push", local.path, Self.remotePath])
        _ = try adb.shell("chmod 755 \(Self.remotePath)")

        let p = Process()
        p.executableURL = adb.sdk.adb
        p.arguments = ["-s", adb.serial, "shell", "\(Self.remotePath) \(width) \(height)"]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting

        // Wait for "ready ..." with a real timeout. availableData blocks, so read on another
        // thread; it returns empty (EOF) if touchd exits.
        let reader = outPipe.fileHandleForReading
        let got = DispatchSemaphore(value: 0)
        let box = LineBox()
        DispatchQueue.global().async {
            var acc = ""
            while !acc.contains("\n") {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                acc += String(decoding: chunk, as: UTF8.self)
            }
            box.set(acc)
            got.signal()
        }
        _ = got.wait(timeout: .now() + 10)
        let line = box.get()
        guard line.hasPrefix("ready") else {
            // Terminate before reading stderr: reading a live pipe would block forever.
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let detail = [line, err].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            throw KestrelError.runtime("touchd did not start: \(detail.isEmpty ? "timed out after 10s" : detail.joined(separator: "; "))")
        }
        readyLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
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
        try stdin.write(contentsOf: Data(text.utf8))
    }

    public func close() {
        try? stdin.write(contentsOf: Data("reset\n".utf8))
        try? stdin.close()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
    }
}
