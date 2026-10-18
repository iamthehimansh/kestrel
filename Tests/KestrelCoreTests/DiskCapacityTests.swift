import XCTest
@testable import KestrelCore

final class DiskCapacityTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("capacity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func header(_ capacity: UInt64, version: UInt32 = 3) -> Data {
        var data = Data(repeating: 0, count: 32)
        data.replaceSubrange(0..<4, with: [0x51, 0x46, 0x49, 0xfb])
        for i in 0..<4 { data[4 + i] = UInt8((version >> (24 - i * 8)) & 0xff) }
        for i in 0..<8 { data[24 + i] = UInt8((capacity >> (56 - i * 8)) & 0xff) }
        return data
    }

    func testMissingDiskUsesRequest() throws {
        XCTAssertNil(try DiskCapacity.bytes(at: directory.appendingPathComponent("missing.img")))
        XCTAssertEqual(try DiskCapacity.setting(requestedGB: 4, directory: directory), "4G")
    }

    func testRawDiskUsesLogicalNotAllocatedSize() throws {
        let url = directory.appendingPathComponent("userdata-qemu.img")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 6 * 1024 * 1024 * 1024)
        try handle.close()
        XCTAssertEqual(try DiskCapacity.setting(requestedGB: 4, directory: directory), "6G")
    }

    func testOverlayVirtualSizeWinsWithoutRoundingDown() throws {
        try header(4 * 1024 * 1024 * 1024, version: 2)
            .write(to: directory.appendingPathComponent("userdata-qemu.img"))
        let size: UInt64 = 6 * 1024 * 1024 * 1024 + 512
        try header(size).write(to: directory.appendingPathComponent("userdata-qemu.img.qcow2"))
        XCTAssertEqual(try DiskCapacity.setting(requestedGB: 2, directory: directory), "\(size)")
        XCTAssertEqual(try DiskCapacity.setting(requestedGB: 8, directory: directory), "8G")
    }

    func testMalformedHeadersFailRatherThanShrinkSilently() throws {
        let url = directory.appendingPathComponent("userdata-qemu.img")
        for bytes in [Data([0x51, 0x46, 0x49, 0xfb]), header(0), header(4096, version: 7), header(UInt64.max)] {
            try bytes.write(to: url)
            XCTAssertThrowsError(try DiskCapacity.bytes(at: url))
        }
        let overlay = directory.appendingPathComponent("userdata-qemu.img.qcow2")
        try Data(repeating: 0, count: 32).write(to: overlay)
        XCTAssertThrowsError(try DiskCapacity.bytes(at: overlay))
    }
}
