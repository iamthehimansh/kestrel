import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

public func runProcess(_ exe: URL, _ args: [String], input: Data? = nil, env: [String: String]? = nil) throws -> CommandResult {
    let p = Process()
    p.executableURL = exe
    p.arguments = args
    if let env { p.environment = env }
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    let inPipe = Pipe()
    p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
    try p.run()
    if let input {
        inPipe.fileHandleForWriting.write(input)
        try? inPipe.fileHandleForWriting.close()
    }
    var outData = Data(), errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    errData = err.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    p.waitUntilExit()
    return CommandResult(status: p.terminationStatus,
                         stdout: String(decoding: outData, as: UTF8.self),
                         stderr: String(decoding: errData, as: UTF8.self))
}

public struct ADB: Sendable {
    public let sdk: AndroidSDK
    public let serial: String

    public init(sdk: AndroidSDK, serial: String) {
        self.sdk = sdk
        self.serial = serial
    }

    @discardableResult
    public func run(_ args: [String]) throws -> String {
        let r = try runProcess(sdk.adb, ["-s", serial] + args)
        if r.status != 0 { throw KestrelError.runtime("adb \(args.joined(separator: " ")) failed: \(r.stderr.isEmpty ? r.stdout : r.stderr)") }
        return r.stdout
    }

    public func shell(_ command: String) throws -> String { try run(["shell", command]) }

    public func install(_ apk: String) throws -> String { try run(["install", "-r", "-g", apk]) }

    public func uninstall(_ package: String) throws -> String { try run(["uninstall", package]) }

    public func launch(_ package: String) throws -> String {
        try shell("monkey -p \(shellQuote(package)) -c android.intent.category.LAUNCHER 1")
    }

    public func forceStop(_ package: String) throws -> String { try shell("am force-stop \(shellQuote(package))") }

    public func packages() throws -> [String] {
        try shell("pm list packages -3").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "package:", with: "") }
            .filter { !$0.isEmpty }.sorted()
    }

    public func screenshot(to path: String) throws {
        // Raw bytes: runProcess decodes stdout as UTF-8, which would corrupt the PNG.
        let p = Process()
        p.executableURL = sdk.adb
        p.arguments = ["-s", serial, "exec-out", "screencap", "-p"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else {
            throw KestrelError.runtime("screencap failed (exit \(p.terminationStatus))")
        }
        try data.write(to: URL(fileURLWithPath: path))
    }
}

public func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
