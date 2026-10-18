import Darwin
import Foundation

public enum PlayerCaptureError: Error, Equatable {
    case invalidLimit, outputTooLarge, invalidUTF8, readFailed
}

/// For short direct children only. Reads stdout without blocking or allowing an unbounded buffer.
public enum PlayerCommandCapture {
    public static func run(executable: URL, arguments: [String], timeout: TimeInterval = 5,
                           maximumBytes: Int = 1_048_576) throws -> String {
        guard timeout.isFinite, timeout > 0, timeout <= 30 else { throw PlayerCommandError.invalidTimeout }
        guard (1...1_048_576).contains(maximumBytes) else { throw PlayerCaptureError.invalidLimit }
        let data = try runData(executable: executable, arguments: arguments, timeout: timeout, maximumBytes: maximumBytes)
        guard let text = String(data: data, encoding: .utf8) else { throw PlayerCaptureError.invalidUTF8 }
        return text
    }

    public static func runData(executable: URL, arguments: [String], timeout: TimeInterval = 5,
                               maximumBytes: Int = 1_048_576) throws -> Data {
        guard timeout.isFinite, timeout > 0, timeout <= 30 else { throw PlayerCommandError.invalidTimeout }
        guard (1...(64 * 1024 * 1024)).contains(maximumBytes) else { throw PlayerCaptureError.invalidLimit }
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        defer { try? reader.close(); try? pipe.fileHandleForWriting.close() }
        let fd = reader.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw PlayerCaptureError.readFailed }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var data = Data()
            var eof = false
            var buffer = [UInt8](repeating: 0, count: 8192)
            while !eof || process.isRunning {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw PlayerCommandError.timedOut }
                if eof {
                    Thread.sleep(forTimeInterval: min(0.01, remaining))
                    continue
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let polled = poll(&descriptor, 1, Int32(max(1, min(50, remaining * 1000))))
                if polled < 0 && errno == EINTR { continue }
                guard polled >= 0 else { throw PlayerCaptureError.readFailed }
                if polled == 0 { continue }
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count >= 0 else { throw PlayerCaptureError.readFailed }
                if count == 0 { eof = true; continue }
                guard count <= maximumBytes - data.count else { throw PlayerCaptureError.outputTooLarge }
                data.append(contentsOf: buffer.prefix(count))
            }
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw PlayerCommandError.failed(process.terminationStatus)
            }
            return data
        } catch {
            if process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + 0.25) == .timedOut {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    guard exited.wait(timeout: .now() + 1) == .success else {
                        throw PlayerCommandError.cleanupFailed
                    }
                }
            }
            throw error
        }
    }
}
