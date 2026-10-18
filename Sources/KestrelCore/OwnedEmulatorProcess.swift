import Darwin
import Foundation

/// Owns a child launched by this app, never a process recovered from a PID file.
/// Call stop off the UI thread. The optional shutdown request must itself be bounded.
public final class OwnedEmulatorProcess {
    private let process: Process
    private let lock = NSLock()
    private let pidFile: URL
    private let pidFD: Int32
    public let processIdentifier: Int32

    init(process: Process, pidFile: URL) {
        self.process = process
        self.pidFile = pidFile
        processIdentifier = process.processIdentifier
        let fd = pidFile.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        var info = stat()
        if fd >= 0, fstat(fd, &info) == 0,
           info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == getuid(),
           info.st_size > 0, info.st_size <= 32 {
            pidFD = fd
        } else {
            if fd >= 0 { Darwin.close(fd) }
            pidFD = -1
        }
    }

    public var isRunning: Bool { process.isRunning }

    public func stop(gracePeriod: TimeInterval = 15, requestShutdown: () throws -> Void = {}) throws {
        guard gracePeriod.isFinite, gracePeriod >= 0, gracePeriod <= 60 else {
            throw KestrelError.invalid("Invalid emulator shutdown grace period")
        }
        lock.lock()
        defer { lock.unlock() }
        if process.isRunning {
            // A failed console request must not prevent cleanup of our retained child.
            try? requestShutdown()
            if !waitForExit(gracePeriod) {
                if process.isRunning { process.terminate() }
                if !waitForExit(2) {
                    if process.isRunning { kill(processIdentifier, SIGKILL) }
                    guard waitForExit(2) else {
                        throw KestrelError.runtime("Owned emulator did not exit")
                    }
                }
            }
        }
        try removeOwnedPIDFile()
    }

    /// The readiness probe must honor its supplied remaining time budget. Waiting does not
    /// transfer ownership: cancellation and errors leave shutdown to the session owner.
    public func waitUntilReady(timeout: TimeInterval, pollInterval: TimeInterval = 0.25,
                               isCancelled: () -> Bool = { false },
                               probe: (TimeInterval) throws -> Bool) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 300,
              pollInterval.isFinite, pollInterval > 0, pollInterval <= 2 else {
            throw KestrelError.invalid("Invalid emulator readiness timeout")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            if isCancelled() { throw CancellationError() }
            guard process.isRunning else { throw KestrelError.runtime("Owned emulator exited during startup") }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw KestrelError.runtime("Emulator readiness timed out") }
            let ready = try probe(remaining)
            if isCancelled() { throw CancellationError() }
            guard process.isRunning else { throw KestrelError.runtime("Owned emulator exited during startup") }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw KestrelError.runtime("Emulator readiness timed out")
            }
            if ready { return }
            let wake = min(deadline, ProcessInfo.processInfo.systemUptime + pollInterval)
            while ProcessInfo.processInfo.systemUptime < wake {
                if isCancelled() { throw CancellationError() }
                Thread.sleep(forTimeInterval: min(0.02, max(0, wake - ProcessInfo.processInfo.systemUptime)))
            }
        }
    }

    private func waitForExit(_ seconds: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while process.isRunning {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return false }
            Thread.sleep(forTimeInterval: min(0.02, remaining))
        }
        return true
    }

    private func removeOwnedPIDFile() throws {
        guard pidFD >= 0 else { return }
        var original = stat()
        var current = stat()
        guard fstat(pidFD, &original) == 0,
              lstat(pidFile.path, &current) == 0,
              current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              original.st_dev == current.st_dev, original.st_ino == current.st_ino else { return }
        var bytes = [UInt8](repeating: 0, count: 33)
        let count = pread(pidFD, &bytes, bytes.count, 0)
        guard count > 0, count <= 32,
              String(bytes: bytes.prefix(count), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) == String(processIdentifier) else { return }
        // Same-user concurrent filesystem mutation is outside this ownership boundary.
        guard unlink(pidFile.path) == 0 || errno == ENOENT else {
            throw KestrelError.runtime("Could not remove owned emulator PID file")
        }
    }

    deinit { if pidFD >= 0 { Darwin.close(pidFD) } }
}
