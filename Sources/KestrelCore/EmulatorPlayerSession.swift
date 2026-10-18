import Foundation

/// Blocking lifecycle operations belong on a worker queue. requestCancellation is safe to
/// call from the UI while start is running; close waits for startup cleanup before returning.
public final class EmulatorPlayerSession: @unchecked Sendable {
    private let launcher: Launcher
    private let index: Int
    private let port: Int
    private let signer = EmulatorTokenSigner()
    private let lifecycle = NSLock()
    private let cancellationLock = NSLock()
    private var cancelled = false
    private var started = false
    private var connected = false
    private var process: OwnedEmulatorProcess?
    private var resources: EmulatorPlayerResources?
    private var policyDirectory: URL?
    private var serial: String?

    public init(store: InstanceStore, index: Int, port: Int) {
        launcher = Launcher(store: store)
        self.index = index
        self.port = port
    }

    public func requestCancellation() {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
    }

    private var isCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancelled
    }

    private func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }

    public func start(coldBoot: Bool = false, snapshot: String? = nil,
                      timeout: TimeInterval = 180) throws -> EmulatorEndpointEvidence {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard !started else { throw KestrelError.invalid("Player session can only start once") }
        started = true
        do {
            try checkCancellation()
            guard timeout.isFinite, timeout > 0, timeout <= 300 else {
                throw KestrelError.invalid("Invalid emulator readiness timeout")
            }
            let instance = try launcher.store.load(index)
            serial = instance.ports.serial
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-session-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            policyDirectory = directory
            let policy = directory.appendingPathComponent("access.json")
            try EmulatorTokenSigner.accessPolicy().write(to: policy, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: policy.path)
            let configuration = try EmulatorPlayerLaunch(port: port, policyFile: policy)
            try checkCancellation()
            let child = try launcher.startOwned(index, coldBoot: coldBoot, snapshot: snapshot, player: configuration)
            process = child
            try launcher.waitForBoot(index, process: child, timeout: timeout, isCancelled: { self.isCancelled })
            try checkCancellation()
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/TemporaryItems/avd/running")
            let endpoint = try EmulatorEndpointDiscovery.inspect(process: child, port: port,
                logFile: launcher.logFile(index), discoveryRoot: root)
            try checkCancellation()
            let registration = try EmulatorPublicKeyRegistration(directory: endpoint.publicKeyDirectory, signer: signer)
            resources = EmulatorPlayerResources(process: child, registration: registration)
            try checkCancellation()
            guard child.isRunning else { throw KestrelError.runtime("Emulator exited during player setup") }
            connected = true
            return endpoint
        } catch {
            let startupError = error
            try cleanup()
            throw startupError
        }
    }

    public func token(for method: EmulatorRPCMethod) throws -> String {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        try checkCancellation()
        guard connected, process?.isRunning == true else {
            throw KestrelError.runtime("Player session is not connected")
        }
        return try signer.token(for: method)
    }

    public func close() throws {
        requestCancellation()
        lifecycle.lock()
        defer { lifecycle.unlock() }
        try cleanup()
    }

    private func cleanup() throws {
        connected = false
        let shutdown = {
            guard let serial = self.serial else { return }
            try PlayerCommandProcess.run(executable: self.launcher.store.sdk.adb,
                arguments: ["-s", serial, "emu", "kill"], timeout: 5)
        }
        if let resources {
            try resources.close(requestShutdown: shutdown)
        } else if let process {
            try process.stop(requestShutdown: shutdown)
        }
        resources = nil
        process = nil
        if let directory = policyDirectory {
            try FileManager.default.removeItem(at: directory)
            policyDirectory = nil
        }
    }
}
