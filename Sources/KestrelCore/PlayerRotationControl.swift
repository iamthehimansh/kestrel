import Foundation

public enum PlayerRotationMode: Equatable, Sendable {
    case free
    case locked(PlayerRotation)

    public static func parse(_ text: String) throws -> Self {
        let fields = text.split(whereSeparator: { $0.isWhitespace })
        if fields == ["free"] { return .free }
        if fields.count == 2, fields[0] == "lock", let value = Int(fields[1]),
           let rotation = PlayerRotation(rawValue: value) { return .locked(rotation) }
        throw KestrelError.invalid("Unrecognized Android rotation mode")
    }

    public var arguments: [String] {
        switch self {
        case .free: return ["wm", "user-rotation", "free"]
        case .locked(let rotation): return ["wm", "user-rotation", "lock", String(rotation.rawValue)]
        }
    }
}

public enum PlayerRotationControlError: Error, Equatable {
    case refused, restorationFailed
}

/// Short, blocking operations; call from a worker, never from the presentation thread.
public enum PlayerRotationControl {
    public static func inspect(adb: URL, serial: String) throws -> PlayerDisplayOrientation {
        do {
            return try PlayerDisplayOrientation.parse(PlayerCommandCapture.run(executable: adb,
                arguments: ["-s", serial, "shell", "dumpsys", "input"], timeout: 2))
        } catch {
            throw KestrelError.runtime("Android display query (dumpsys input) failed: \(error)")
        }
    }

    public static func rotate(adb: URL, serial: String,
                              isCancelled: () -> Bool = { false }) throws -> PlayerDisplayOrientation {
        try rotate(command: { args in
            try PlayerCommandCapture.run(executable: adb, arguments: ["-s", serial, "shell"] + args, timeout: 2)
        }, wait: { Thread.sleep(forTimeInterval: 0.1) }, isCancelled: isCancelled)
    }

    static func rotate(command: ([String]) throws -> String, wait: () -> Void,
                       isCancelled: () -> Bool = { false }) throws -> PlayerDisplayOrientation {
        if isCancelled() { throw CancellationError() }
        let previousMode = try PlayerRotationMode.parse(command(["wm", "user-rotation"]))
        let previous = try PlayerDisplayOrientation.parse(command(["dumpsys", "input"]))
        let next = PlayerRotation(rawValue: (previous.rotation.rawValue + 1) % 4)!
        let physical = previous.rotation.logicalSize(width: previous.width, height: previous.height)
        let expected = next.logicalSize(width: physical.width, height: physical.height)
        if isCancelled() { throw CancellationError() }
        do {
            _ = try command(PlayerRotationMode.locked(next).arguments)
            for _ in 0..<12 {
                if isCancelled() { throw CancellationError() }
                wait()
                if isCancelled() { throw CancellationError() }
                let current = try PlayerDisplayOrientation.parse(command(["dumpsys", "input"]))
                if isCancelled() { throw CancellationError() }
                if current.rotation == next, current.width == expected.width, current.height == expected.height {
                    return current
                }
            }
            throw PlayerRotationControlError.refused
        } catch {
            let failure = error
            do {
                _ = try command(previousMode.arguments)
                guard try PlayerRotationMode.parse(command(["wm", "user-rotation"])) == previousMode else {
                    throw PlayerRotationControlError.restorationFailed
                }
                var restored = false
                for _ in 0..<12 {
                    if try PlayerDisplayOrientation.parse(command(["dumpsys", "input"])) == previous {
                        restored = true
                        break
                    }
                    wait()
                }
                guard restored else { throw PlayerRotationControlError.restorationFailed }
            } catch { throw PlayerRotationControlError.restorationFailed }
            throw failure
        }
    }
}
