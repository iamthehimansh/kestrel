import Foundation

/// Captures structural focus evidence only; callers must not persist raw command output.
public enum PlayerGuestTextObserver {
    public static func inspect(adb: URL, serial: String, timeout: TimeInterval = 0.5) throws -> PlayerGuestTextFocus? {
        try inspect(timeout: timeout, clock: { ProcessInfo.processInfo.systemUptime }) { arguments, remaining in
            try PlayerCommandCapture.run(executable: adb, arguments: ["-s", serial, "shell"] + arguments,
                                         timeout: remaining, maximumBytes: 1_048_576)
        }
    }

    static func inspect(timeout: TimeInterval, clock: () -> TimeInterval,
                        command: ([String], TimeInterval) throws -> String) throws -> PlayerGuestTextFocus? {
        guard timeout.isFinite, timeout > 0, timeout <= 2 else { throw PlayerCommandError.invalidTimeout }
        let began = clock()
        guard began.isFinite, began >= 0 else { throw PlayerCommandError.invalidTimeout }
        let deadline = began + timeout
        func capture(_ args: [String]) throws -> String {
            try Task.checkCancellation()
            let now = clock()
            guard now.isFinite, now >= began, now < deadline else { throw PlayerCommandError.timedOut }
            return try command(args, deadline - now)
        }
        let before = try capture(["dumpsys", "window", "displays"])
        let input = try capture(["dumpsys", "input_method"])
        let after = try capture(["dumpsys", "window", "displays"])
        try Task.checkCancellation()
        let ended = clock()
        guard ended.isFinite, ended >= began, ended < deadline else { throw PlayerCommandError.timedOut }
        return PlayerGuestTextFocus.validated(inputMethodDump: input, windowBefore: before, windowAfter: after)
    }
}
