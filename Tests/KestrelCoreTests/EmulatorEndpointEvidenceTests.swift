import Foundation
import XCTest
@testable import KestrelCore

final class EmulatorEndpointEvidenceTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/kestrel-discovery-tests")
    private let identifier = "d2be96b5-e39e-4f66-bfd1-3d705858b06d"
    private func log(pid: Int32 = 123, address: String = "127.0.0.1:8556", auth: String = "+jwt") -> String {
        "INFO | Scanning \(root.path)/\(pid)/jwks/\(identifier) for jwk keys.\n" +
        "INFO | Started GRPC server at \(address), security: Local, auth: \(auth)\n"
    }
    private func listeners(_ address: String = "127.0.0.1:8556", pid: Int32 = 123) -> String {
        "p\(pid)\nf45\nn\(address)\nTST=LISTEN\n"
    }

    func testCrossChecksLogProcessDirectoryAndSocket() throws {
        let result = try EmulatorEndpointEvidence.parse(log: log(), sockets: listeners(), pid: 123,
                                                        port: 8556, discoveryRoot: root)
        XCTAssertEqual(result.host, "127.0.0.1")
        XCTAssertEqual(result.port, 8556)
        XCTAssertEqual(result.publicKeyDirectory.path, root.appendingPathComponent("123/jwks/\(identifier)").path)
        let ipv6 = try EmulatorEndpointEvidence.parse(log: log(address: "[::1]:8556"),
            sockets: listeners("[::1]:8556"), pid: 123, port: 8556, discoveryRoot: root)
        XCTAssertEqual(ipv6.host, "::1")
    }

    func testRejectsMissingWrongOrWildcardListeners() {
        for socket in ["", listeners("*:8556"), listeners("0.0.0.0:8556"), listeners("127.0.0.1:8557"),
                       listeners(pid: 999), listeners() + "f46\nn*:8556\nTST=LISTEN\n",
                       "p123\nf45\nn127.0.0.1:8556\nTST=ESTABLISHED\n"] {
            XCTAssertThrowsError(try EmulatorEndpointEvidence.parse(log: log(), sockets: socket,
                pid: 123, port: 8556, discoveryRoot: root))
        }
    }

    func testRejectsUnauthenticatedOrAmbiguousLog() {
        for text in [log(auth: "none"), log(address: "0.0.0.0:8556"), log(pid: 124),
                     log() + log(), log().replacingOccurrences(of: "/123/jwks/", with: "/123/../jwks/"),
                     log().replacingOccurrences(of: root.path, with: "/tmp/another-process") ] {
            XCTAssertThrowsError(try EmulatorEndpointEvidence.parse(log: text, sockets: listeners(),
                pid: 123, port: 8556, discoveryRoot: root))
        }
    }

    func testRejectsInvalidInputsAndOversizedEvidence() {
        for pid in [Int32(0), Int32(-1)] {
            XCTAssertThrowsError(try EmulatorEndpointEvidence.parse(log: log(), sockets: listeners(),
                pid: pid, port: 8556, discoveryRoot: root))
        }
        XCTAssertThrowsError(try EmulatorEndpointEvidence.parse(log: String(repeating: "x", count: 1_048_577),
            sockets: listeners(), pid: 123, port: 8556, discoveryRoot: root))
        XCTAssertThrowsError(try EmulatorEndpointEvidence.parse(log: log(), sockets: listeners(),
            pid: 123, port: 80, discoveryRoot: root))
    }
}
