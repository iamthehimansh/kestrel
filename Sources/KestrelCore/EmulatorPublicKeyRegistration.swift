import Darwin
import Foundation

/// Publishes only a public JWK. The caller must first establish that this directory belongs
/// to its authenticated emulator process; directory permissions alone do not prove that.
/// Directory and file descriptors stay pinned until revocation to avoid pathname retargeting
/// and inode reuse. This does not defend against a malicious process running as the same user.
public final class EmulatorPublicKeyRegistration {
    public let fileName: String
    private let lock = NSLock()
    private var directoryFD: Int32 = -1
    private var fileFD: Int32 = -1
    private var revoked = false

    public init(directory: URL, signer: EmulatorTokenSigner) throws {
        guard directory.isFileURL else {
            throw KestrelError.invalid("Public-key directory must be local")
        }
        let bytes = try signer.publicKeySet()
        guard !bytes.isEmpty, bytes.count <= 4096 else {
            throw KestrelError.invalid("Invalid public-key document size")
        }
        let name = "kestrel-" + signer.keyID + ".jwk"
        let dir = directory.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard dir >= 0 else { throw KestrelError.invalid("Could not open public-key directory safely") }
        var keepDirectory = false
        defer { if !keepDirectory { Darwin.close(dir) } }
        var directoryInfo = stat()
        guard fstat(dir, &directoryInfo) == 0,
              directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_uid == getuid(), directoryInfo.st_mode & 0o022 == 0 else {
            throw KestrelError.invalid("Public-key directory has unsafe ownership or permissions")
        }

        // The watcher only accepts .jwk files. Stage complete bytes under another extension,
        // then publish via an exclusive hard link so it never sees a partially written key.
        let staging = ".kestrel-" + UUID().uuidString.lowercased() + ".pending"
        let fd = staging.withCString { openat(dir, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
        guard fd >= 0 else { throw KestrelError.runtime("Could not stage public key") }
        var keepFile = false
        defer {
            staging.withCString { _ = unlinkat(dir, $0, 0) }
            if !keepFile { Darwin.close(fd) }
        }
        guard fchmod(fd, mode_t(0o600)) == 0 else {
            throw KestrelError.runtime("Could not set public-key file permissions")
        }
        try bytes.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw KestrelError.runtime("Public-key write failed") }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw KestrelError.runtime("Public-key flush failed") }
        let published = staging.withCString { source in
            name.withCString { destination in linkat(dir, source, dir, destination, 0) }
        }
        guard published == 0 else {
            throw KestrelError.runtime("Could not publish public key without replacing an existing file")
        }
        fileName = name
        directoryFD = dir
        fileFD = fd
        keepFile = true
        keepDirectory = true
    }

    /// Removes only the still-identical file created by this registration. Missing is already
    /// revoked; a replacement is an error and is left alone. Concurrent same-user mutation
    /// between identity check and unlink is outside this filesystem ownership boundary.
    public func revoke() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked else { return }
        var original = stat()
        guard fstat(fileFD, &original) == 0 else {
            throw KestrelError.runtime("Public-key descriptor is no longer valid")
        }
        var current = stat()
        let found = fileName.withCString { fstatat(directoryFD, $0, &current, AT_SYMLINK_NOFOLLOW) }
        if found != 0 {
            guard errno == ENOENT else { throw KestrelError.runtime("Could not inspect registered public key") }
        } else {
            guard current.st_dev == original.st_dev, current.st_ino == original.st_ino,
                  current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw KestrelError.runtime("Registered public key was replaced; refusing to delete replacement")
            }
            let removed = fileName.withCString { unlinkat(directoryFD, $0, 0) }
            guard removed == 0 || errno == ENOENT else {
                throw KestrelError.runtime("Public-key revocation failed")
            }
        }
        revoked = true
        Darwin.close(fileFD)
        Darwin.close(directoryFD)
        fileFD = -1
        directoryFD = -1
    }

    deinit {
        try? revoke()
        if fileFD >= 0 { Darwin.close(fileFD) }
        if directoryFD >= 0 { Darwin.close(directoryFD) }
    }
}
