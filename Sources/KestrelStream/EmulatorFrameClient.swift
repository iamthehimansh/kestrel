import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import KestrelCore

/// Local emulator endpoints only. No DNS resolution or remote bearer-credential transport.
@available(macOS 15, *)
public struct EmulatorFrameEndpoint: Sendable {
    public let host: String
    public let port: Int

    public init(host: String, port: Int) throws {
        guard ["127.0.0.1", "::1"].contains(host), (1024...65535).contains(port) else {
            throw KestrelError.invalid("Frame endpoint must be a literal loopback address and an unprivileged port")
        }
        self.host = host
        self.port = port
    }

    fileprivate func transport() throws -> HTTP2ClientTransport.Posix {
        // JWT authentication remains mandatory. The emulator listener must be independently
        // verified as loopback-only by its process owner before publishing a public key.
        if host == "::1" {
            return try HTTP2ClientTransport.Posix(target: .ipv6(address: host, port: port), transportSecurity: .plaintext)
        }
        return try HTTP2ClientTransport.Posix(target: .ipv4(address: host, port: port), transportSecurity: .plaintext)
    }
}

@available(macOS 15, *)
public struct EmulatorFrameRequest: Sendable {
    public let width: Int
    public let height: Int
    public let seconds: Int
    public let maximumPixelBytes: Int

    public init(width: Int, height: Int, seconds: Int = 30) throws {
        guard (1...PlayerFrame.maximumDimension).contains(width),
              (1...PlayerFrame.maximumDimension).contains(height), (1...60).contains(seconds) else {
            throw KestrelError.invalid("Invalid frame request dimensions or duration")
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !overflow, !byteOverflow, bytes <= PlayerFrame.maximumBytes else {
            throw KestrelError.invalid("Frame request exceeds pixel memory budget")
        }
        self.width = width
        self.height = height
        self.seconds = seconds
        maximumPixelBytes = bytes
    }

    var message: Android_Emulation_Control_ImageFormat {
        var request = Android_Emulation_Control_ImageFormat()
        request.format = .rgba8888
        request.width = UInt32(width)
        request.height = UInt32(height)
        return request
    }

    var options: CallOptions {
        var options = CallOptions.defaults
        options.timeout = .seconds(seconds)
        options.waitForReady = false
        // grpc-swift-nio-transport 2.11.0 also uses the request limit for its inbound
        // deframer (Connection.makeStream). Keep both bounded to the validated frame size.
        options.maxRequestMessageBytes = maximumPixelBytes + 64 * 1024
        options.maxResponseMessageBytes = maximumPixelBytes + 64 * 1024
        return options
    }
}

@available(macOS 15, *)
struct EmulatorFrameDecoder {
    let request: EmulatorFrameRequest
    private var lastSequence: UInt32?

    init(request: EmulatorFrameRequest) { self.request = request }

    mutating func decode(_ image: Android_Emulation_Control_Image) throws -> PlayerFrame? {
        guard image.hasFormat, image.format.format == .rgba8888, image.format.display == 0 else {
            throw KestrelError.invalid("Unsupported emulator frame format or display")
        }
        let width = Int(image.format.width)
        let height = Int(image.format.height)
        // The protocol explicitly represents a not-yet-available screen with zero dimensions.
        if width == 0 && height == 0 && image.image.isEmpty { return nil }
        guard width > 0, height > 0, width <= request.width, height <= request.height else {
            throw KestrelError.invalid("Emulator frame exceeds requested dimensions")
        }
        if let lastSequence, image.seq <= lastSequence {
            throw KestrelError.invalid("Emulator frame sequence did not advance")
        }
        let frame = try PlayerFrame(width: width, height: height, bytesPerRow: width * 4,
                                    sequence: UInt64(image.seq), timestampMicroseconds: image.timestampUs,
                                    rgba: image.image, sensorRotation: image.format.hasRotation
                                        ? PlayerRotation(rawValue: image.format.rotation.rotation.rawValue) : nil)
        lastSequence = image.seq
        return frame
    }
}

/// Safe errors deliberately omit server messages/metadata, which may contain credentials.
public enum EmulatorFrameConnectionError: Error, Sendable, Equatable {
    case invalidCredential, rejected, timedOut, unavailable, invalidFrame, transport
    case rpcStatus(Int)
    case protocolFailure(String)
}

@available(macOS 15, *)
public struct EmulatorFrameClient: Sendable {
    public let endpoint: EmulatorFrameEndpoint

    public init(endpoint: EmulatorFrameEndpoint) { self.endpoint = endpoint }

    private func metadata(_ credential: String) throws -> Metadata {
        guard !credential.isEmpty, credential.utf8.count <= 4096,
              credential.split(separator: ".", omittingEmptySubsequences: false).count == 3,
              credential.utf8.allSatisfy({ (45...57).contains($0) && $0 != 47 ||
                  (65...90).contains($0) || $0 == 95 || (97...122).contains($0) }) else {
            throw EmulatorFrameConnectionError.invalidCredential
        }
        return ["authorization": .string("Bearer " + credential)]
    }

    public func screenshot(_ request: EmulatorFrameRequest, credential: String) async throws -> PlayerFrame? {
        let metadata = try metadata(credential)
        do {
            return try await withGRPCClient(transport: endpoint.transport()) { client in
                let stub = Android_Emulation_Control_EmulatorController.Client(wrapping: client)
                let image = try await stub.getScreenshot(request.message, metadata: metadata, options: request.options)
                var decoder = EmulatorFrameDecoder(request: request)
                return try decoder.decode(image)
            }
        } catch { throw sanitized(error) }
    }

    /// A single bounded RPC. The host renews credentials/restarts with a fresh mailbox epoch
    /// when it expires. Returning false from onFrame cancels the RPC without queuing history.
    /// The callback must be fast: offer to a bounded mailbox, never render or block here.
    public func stream(_ request: EmulatorFrameRequest, credential: String,
                       onFrame: @Sendable @escaping (PlayerFrame) -> Bool) async throws -> Int {
        let metadata = try metadata(credential)
        do {
            return try await withGRPCClient(transport: endpoint.transport()) { client in
                let stub = Android_Emulation_Control_EmulatorController.Client(wrapping: client)
                return try await stub.streamScreenshot(request.message, metadata: metadata, options: request.options) { response in
                    var decoder = EmulatorFrameDecoder(request: request)
                    var count = 0
                    for try await image in response.messages {
                        try Task.checkCancellation()
                        if let frame = try decoder.decode(image) {
                            count += 1
                            if !onFrame(frame) { break }
                        }
                    }
                    return count
                }
            }
        } catch { throw sanitized(error) }
    }

    public func sendKey(_ request: EmulatorKeyboardRequest, credential: String) async throws {
        try Task.checkCancellation()
        let metadata = try metadata(credential)
        do {
            try await withGRPCClient(transport: endpoint.transport()) { client in
                let stub = Android_Emulation_Control_EmulatorController.Client(wrapping: client)
                for keypress in request.individualKeypresses {
                    try Task.checkCancellation()
                    _ = try await stub.sendKey(keypress.message, metadata: metadata, options: keypress.options)
                    // Match the bounded single-key diagnostic path; cancellation during
                    // this gap prevents the next character, but cannot undo a sent key.
                    try await Task.sleep(for: .milliseconds(30))
                }
            }
        } catch { throw sanitized(error) }
    }

    private func sanitized(_ error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if error is KestrelError { return EmulatorFrameConnectionError.invalidFrame }
        if let error = error as? RPCError {
            if error.code == .internalError {
                // Match known library diagnostics to fixed labels; never return raw messages.
                let labels = [("Failed to decode message", "message_decode"),
                              ("Missing content-type header", "missing_content_type"),
                              ("compression algorithm", "compression_negotiation"),
                              ("no decompressor", "decompressor_missing"),
                              ("Decompression error", "decompression"),
                              ("The stream from the client transport is invalid", "unary_stream_shape"),
                              ("Invalid stream.", "initial_metadata"),
                              ("Server sent EOS", "missing_trailers")]
                if let label = labels.first(where: { error.message.contains($0.0) })?.1 {
                    return EmulatorFrameConnectionError.protocolFailure(label)
                }
            }
            switch error.code {
            case .unauthenticated, .permissionDenied: return EmulatorFrameConnectionError.rejected
            case .deadlineExceeded: return EmulatorFrameConnectionError.timedOut
            case .unavailable: return EmulatorFrameConnectionError.unavailable
            default: return EmulatorFrameConnectionError.rpcStatus(error.code.rawValue)
            }
        }
        return EmulatorFrameConnectionError.transport
    }
}
