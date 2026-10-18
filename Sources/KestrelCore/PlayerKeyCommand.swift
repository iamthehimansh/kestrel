import Darwin
import Foundation

public enum PlayerKeyCommand: String, CaseIterable, Sendable {
    case back, home, recents, menu, volumeUp, volumeDown

    public func arguments(serial: String) -> [String] {
        let code: String
        switch self {
        case .back: code = "4"
        case .home: code = "3"
        case .recents: code = "187"
        case .menu: code = "82"
        case .volumeUp: code = "24"
        case .volumeDown: code = "25"
        }
        return ["-s", serial, "shell", "input", "keyevent", code]
    }
}

public enum PlayerCommandError: Error, Equatable, Sendable {
    case invalidTimeout, timedOut, failed(Int32), cleanupFailed
}

/// Runs only the caller-selected executable with fixed argv. Output is discarded to avoid
/// pipe backpressure. This is for short control commands, not processes that spawn workers.
public enum PlayerCommandProcess {
    public static func run(executable: URL, arguments: [String], timeout: TimeInterval = 5) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 30 else { throw PlayerCommandError.invalidTimeout }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 0.25) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                guard exited.wait(timeout: .now() + 1) == .success else {
                    throw PlayerCommandError.cleanupFailed
                }
            }
            throw PlayerCommandError.timedOut
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw PlayerCommandError.failed(process.terminationStatus)
        }
    }
}

/// At most one accepted command, with no waiting backlog. close() prevents new commands
/// and suppresses late callbacks. Already-running commands retain their bounded timeout.
public final class PlayerCommandDispatcher: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "kestrel.player.commands", qos: .userInitiated)
    private let execute: @Sendable (PlayerKeyCommand) throws -> Void
    private var busy = false
    private var closed = false

    public convenience init(sdk: AndroidSDK, serial: String) {
        self.init { command in
            try PlayerCommandProcess.run(executable: sdk.adb, arguments: command.arguments(serial: serial))
        }
    }

    init(execute: @escaping @Sendable (PlayerKeyCommand) throws -> Void) {
        self.execute = execute
    }

    @discardableResult
    public func submit(_ command: PlayerKeyCommand,
                       completion: @escaping (Result<Void, Error>) -> Void) -> Bool {
        lock.lock()
        guard !closed, !busy else { lock.unlock(); return false }
        busy = true
        lock.unlock()
        queue.async { [self] in
            lock.lock()
            let shouldRun = !closed
            lock.unlock()
            let result = Result { if shouldRun { try execute(command) } }
            DispatchQueue.main.async { [self] in
                lock.lock()
                busy = false
                let shouldComplete = !closed && shouldRun
                lock.unlock()
                if shouldComplete { completion(result) }
            }
        }
        return true
    }

    public func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}
