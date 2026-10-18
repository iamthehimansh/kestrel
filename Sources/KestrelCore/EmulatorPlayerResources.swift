import Foundation

public enum EmulatorPlayerCleanupError: Error, Equatable {
    case incomplete(keyRevocationFailed: Bool, processShutdownFailed: Bool)
}

/// Session-owned resources after endpoint verification and public-key registration.
/// Stop input/video producers before closing, and call close off the UI thread.
public final class EmulatorPlayerResources {
    private let process: OwnedEmulatorProcess
    private let registration: EmulatorPublicKeyRegistration
    private let lock = NSLock()
    private var closed = false

    public init(process: OwnedEmulatorProcess, registration: EmulatorPublicKeyRegistration) {
        self.process = process
        self.registration = registration
    }

    public func close(gracePeriod: TimeInterval = 15, requestShutdown: () throws -> Void = {}) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        var keyFailed = false
        var processFailed = false
        do { try registration.revoke() } catch { keyFailed = true }
        do { try process.stop(gracePeriod: gracePeriod, requestShutdown: requestShutdown) }
        catch { processFailed = true }
        guard !keyFailed, !processFailed else {
            throw EmulatorPlayerCleanupError.incomplete(keyRevocationFailed: keyFailed,
                                                       processShutdownFailed: processFailed)
        }
        closed = true
    }
}
