import Darwin
import Foundation

/// Explicit opt-in to the authenticated native-player endpoint. Policy files contain no
/// private key material. The session owner must also verify the actual loopback listener
/// and its process identity before publishing a public JWK or sending a bearer credential.
public struct EmulatorPlayerLaunch: Sendable {
    public let port: Int
    public let policyFile: URL

    public init(port: Int, policyFile: URL) throws {
        guard (1024...65535).contains(port), policyFile.isFileURL else {
            throw KestrelError.invalid("Player endpoint requires an unprivileged port and a local policy file")
        }
        self.port = port
        self.policyFile = policyFile.standardizedFileURL
    }

    public func validate(for ports: Ports) throws {
        guard port != ports.console, port != ports.adb else {
            throw KestrelError.invalid("Player endpoint conflicts with an emulator control port")
        }
        let fd = policyFile.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) }
        guard fd >= 0 else { throw KestrelError.invalid("Could not open player policy safely") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(), info.st_mode & 0o022 == 0,
              info.st_size > 0, info.st_size <= 4096 else {
            throw KestrelError.invalid("Player policy must be a small, owned, non-writable-by-others regular file")
        }
        var bytes = Data(count: Int(info.st_size))
        let length = bytes.count
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!, length) }
        guard count == length, bytes == (try EmulatorTokenSigner.accessPolicy()) else {
            throw KestrelError.invalid("Player policy differs from the required authenticated read-only policy")
        }
    }
}
