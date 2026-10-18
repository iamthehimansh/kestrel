import Darwin
import Foundation

enum TouchWriteError: Error, Equatable {
    case invalidRequest, busy, closed, timedOut
    case system(Int32)
}

/// Owns its pipe handle. Writes are nonblocking at the descriptor level and bounded by a
/// monotonic deadline. A partial/failed write closes the stream: resuming a text command at
/// an unknown boundary could turn a release into a different operation.
final class BoundedTouchWriter {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(handle: FileHandle) throws {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else { throw TouchWriteError.system(errno) }
        guard fcntl(fd, F_SETNOSIGPIPE, 1) == 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = errno
            try? handle.close()
            throw TouchWriteError.system(code)
        }
        self.handle = handle
    }

    func write(_ data: Data, timeout: TimeInterval = 0.1) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 1, data.count <= 1_048_576 else {
            throw TouchWriteError.invalidRequest
        }
        // Never wait indefinitely behind another producer; the caller must serialize input.
        guard lock.try() else { throw TouchWriteError.busy }
        defer { lock.unlock() }
        guard let handle else { throw TouchWriteError.closed }
        if data.isEmpty { return }
        let fd = handle.fileDescriptor
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { throw TouchWriteError.timedOut }
                    let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written > 0 {
                        offset += written
                        continue
                    }
                    if written == 0 { throw TouchWriteError.closed }
                    let code = errno
                    if code == EINTR { continue }
                    guard code == EAGAIN || code == EWOULDBLOCK else { throw TouchWriteError.system(code) }
                    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let milliseconds = Int32(max(1, ceil(remaining * 1000)))
                    let ready = poll(&descriptor, 1, milliseconds)
                    if ready == 0 { throw TouchWriteError.timedOut }
                    if ready < 0 {
                        if errno == EINTR { continue }
                        throw TouchWriteError.system(errno)
                    }
                    if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                        throw TouchWriteError.closed
                    }
                }
            }
        } catch {
            closeLocked()
            throw error
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    private func closeLocked() {
        try? handle?.close()
        handle = nil
    }

    deinit { close() }
}
