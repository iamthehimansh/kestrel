import Foundation

/// Reads capacity without launching qemu-img or modifying userdata. A .img file may itself
/// be QCOW2, so format identification must use magic bytes rather than the filename.
enum DiskCapacity {
    static func bytes(at url: URL) throws -> UInt64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try file.read(upToCount: 32) ?? Data()
        if header.starts(with: [0x51, 0x46, 0x49, 0xfb]) {
            guard header.count == 32 else {
                throw KestrelError.invalid("Truncated QCOW2 header in \(url.lastPathComponent)")
            }
            let version = header[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let capacity = header[24..<32].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard (version == 2 || version == 3), capacity > 0, capacity <= UInt64(Int64.max) else {
                throw KestrelError.invalid("Invalid QCOW2 capacity or version in \(url.lastPathComponent)")
            }
            return capacity
        }
        guard url.pathExtension != "qcow2" else {
            throw KestrelError.invalid("Invalid QCOW2 magic in \(url.lastPathComponent)")
        }
        return try file.seekToEnd()
    }

    static func setting(requestedGB: Int, directory: URL) throws -> String {
        let gib: UInt64 = 1_073_741_824
        var capacity = UInt64(requestedGB) * gib
        for name in ["userdata-qemu.img", "userdata-qemu.img.qcow2"] {
            if let existing = try bytes(at: directory.appendingPathComponent(name)) {
                capacity = max(capacity, existing)
            }
        }
        return capacity % gib == 0 ? "\(capacity / gib)G" : "\(capacity)"
    }
}
