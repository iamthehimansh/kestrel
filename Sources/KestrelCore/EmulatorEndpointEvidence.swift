import Foundation

/// Cross-checks bounded startup-log and `lsof -FpnT` evidence collected by the process owner.
/// This parser does not obtain evidence, prove executable identity, or eliminate PID reuse.
/// The caller must collect current socket evidence from its still-owned emulator process.
public struct EmulatorEndpointEvidence: Sendable {
    public let host: String
    public let port: Int
    public let publicKeyDirectory: URL

    public static func parse(log: String, sockets: String, pid: Int32, port: Int,
                             discoveryRoot: URL) throws -> EmulatorEndpointEvidence {
        guard pid > 0, (1024...65535).contains(port), discoveryRoot.isFileURL,
              log.utf8.count <= 1_048_576, sockets.utf8.count <= 65_536,
              !log.contains("\0"), !sockets.contains("\0") else {
            throw KestrelError.invalid("Invalid emulator endpoint evidence bounds")
        }
        let lines = log.components(separatedBy: .newlines)
        let announcements = lines.filter { $0.contains("Started GRPC server at ") }
        let directories = lines.filter { $0.contains(" for jwk keys.") }
        guard announcements.count == 1, directories.count == 1 else {
            throw KestrelError.invalid("Missing or ambiguous emulator endpoint announcements")
        }
        let announcement = announcements[0]
        guard let start = announcement.range(of: "Started GRPC server at "),
              announcement.hasSuffix(", security: Local, auth: +jwt") else {
            throw KestrelError.invalid("Emulator endpoint is not explicitly JWT protected")
        }
        let endpoint = String(announcement[start.upperBound...].dropLast(", security: Local, auth: +jwt".count))
        let host: String
        switch endpoint {
        case "127.0.0.1:\(port)": host = "127.0.0.1"
        case "[::1]:\(port)": host = "::1"
        default: throw KestrelError.invalid("Emulator announcement is not the requested loopback endpoint")
        }

        guard let scanning = directories[0].range(of: "Scanning ") else {
            throw KestrelError.invalid("Missing public-key directory announcement")
        }
        let rawPath = String(directories[0][scanning.upperBound...].dropLast(" for jwk keys.".count))
        let expectedParent = discoveryRoot.appendingPathComponent("\(pid)/jwks").path + "/"
        guard rawPath.hasPrefix(expectedParent) else {
            throw KestrelError.invalid("Public-key directory does not belong to the expected process path")
        }
        let name = String(rawPath.dropFirst(expectedParent.count))
        guard UUID(uuidString: name) != nil, name.count == 36,
              !name.contains("/"), !rawPath.contains("/../"), !rawPath.contains("/./") else {
            throw KestrelError.invalid("Invalid public-key directory component")
        }
        let publicDirectory = URL(fileURLWithPath: rawPath)
        guard publicDirectory.standardizedFileURL.path == rawPath else {
            throw KestrelError.invalid("Public-key path is not canonical within the discovery root")
        }

        var processSeen = false
        var address: String?
        var listening = false
        var descriptorSeen = false
        var listenerCount = 0
        func finishDescriptor() throws {
            guard descriptorSeen else { return }
            guard listening, address == endpoint else {
                throw KestrelError.invalid("Socket evidence includes a nonmatching or non-listening endpoint")
            }
            listenerCount += 1
        }
        for line in sockets.components(separatedBy: .newlines) where !line.isEmpty {
            switch line.first {
            case "p":
                guard !processSeen, !descriptorSeen, line == "p\(pid)" else {
                    throw KestrelError.invalid("Socket process identity is missing or conflicting")
                }
                processSeen = true
            case "f":
                guard processSeen, Int(line.dropFirst()) != nil else {
                    throw KestrelError.invalid("Malformed socket descriptor evidence")
                }
                try finishDescriptor()
                descriptorSeen = true
                address = nil
                listening = false
            case "n":
                guard descriptorSeen, address == nil else {
                    throw KestrelError.invalid("Ambiguous socket address evidence")
                }
                address = String(line.dropFirst())
            case "T":
                guard descriptorSeen else { throw KestrelError.invalid("Socket state without descriptor") }
                if line.hasPrefix("TST=") {
                    guard !listening, line == "TST=LISTEN" else {
                        throw KestrelError.invalid("Socket is not listening")
                    }
                    listening = true
                } else if !line.hasPrefix("TQR=") && !line.hasPrefix("TQS=") {
                    throw KestrelError.invalid("Unexpected socket state field")
                }
            default:
                throw KestrelError.invalid("Unexpected socket evidence field")
            }
        }
        try finishDescriptor()
        guard processSeen, listenerCount > 0 else {
            throw KestrelError.invalid("No matching emulator listener observed")
        }
        return EmulatorEndpointEvidence(host: host, port: port, publicKeyDirectory: publicDirectory)
    }
}
