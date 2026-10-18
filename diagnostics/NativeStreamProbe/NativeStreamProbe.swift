import Foundation
import Darwin
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import KestrelCore
import KestrelStream

private final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        total += 1
        return total
    }
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return total
    }
}

private final class ProbeProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "initializing"
    func set(_ stage: String) { lock.lock(); value = stage; lock.unlock() }
    var stage: String { lock.lock(); defer { lock.unlock() }; return value }
}

@main
struct NativeStreamProbe {
    private static let progress = ProbeProgress()

    static func reply(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    @available(macOS 15, *)
    static func run() async throws {
        let signer = EmulatorTokenSigner()
        try reply(["jwks": JSONSerialization.jsonObject(with: signer.publicKeySet()),
                   "policy": JSONSerialization.jsonObject(with: EmulatorTokenSigner.accessPolicy()),
                   "key_id": signer.keyID])
        guard let line = readLine(), line.utf8.count < 8192,
              let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let host = request["host"] as? String, let port = request["port"] as? Int,
              let screenshotPath = request["screenshot"] as? String else {
            throw KestrelError.invalid("Bad diagnostic request")
        }
        var registration: EmulatorPublicKeyRegistration?
        if let directory = request["registration_directory"] as? String {
            progress.set("public_key_registration")
            registration = try EmulatorPublicKeyRegistration(directory: URL(fileURLWithPath: directory), signer: signer)
        }
        defer { try? registration?.revoke() }
        let endpoint = try EmulatorFrameEndpoint(host: host, port: port)
        let client = EmulatorFrameClient(endpoint: endpoint)
        let format = try EmulatorFrameRequest(width: 1280, height: 720, seconds: 10)
        progress.set("authenticated_screenshot")
        var frame: PlayerFrame?
        // The emulator observes public-key directory changes asynchronously. Retry only
        // explicit auth rejection, never mask frame/transport errors.
        for attempt in 0..<20 {
            do {
                frame = try await client.screenshot(format, credential: signer.token(for: .getScreenshot))
                break
            } catch EmulatorFrameConnectionError.rejected {
                if attempt == 19 { throw EmulatorFrameConnectionError.rejected }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let frame, frame.width == 1280, frame.height == 720 else {
            throw KestrelError.runtime("Expected a complete 720p frame")
        }
        progress.set("png_write")
        try writePNG(frame, path: screenshotPath)
        progress.set("wrong_audience")
        do {
            _ = try await client.screenshot(format, credential: signer.token(for: .streamScreenshot))
            throw KestrelError.runtime("Wrong-audience token was accepted")
        } catch EmulatorFrameConnectionError.rejected { }

        progress.set("bounded_stream")
        let counter = FrameCounter()
        let start = ContinuousClock.now
        let delivered = try await client.stream(format, credential: signer.token(for: .streamScreenshot)) { _ in
            counter.increment() < 90
        }
        let stopped = start.duration(to: .now)
        guard delivered == 90, counter.count == 90, stopped < .seconds(8) else {
            throw KestrelError.runtime("Early stream termination did not finish within budget")
        }

        progress.set("cancel_active_stream")
        let cancellationCounter = FrameCounter()
        let credential = try signer.token(for: .streamScreenshot)
        let task = Task {
            try await client.stream(format, credential: credential) { _ in
                _ = cancellationCounter.increment()
                return true
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while cancellationCounter.count == 0 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let cancelAt = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            throw KestrelError.runtime("Cancelled stream returned success")
        } catch is CancellationError { }
        let cancellationDuration = cancelAt.duration(to: .now)
        guard cancellationCounter.count > 0, cancellationDuration < .seconds(2) else {
            throw KestrelError.runtime("Cancellation did not promptly stop an active stream")
        }
        let afterCancel = cancellationCounter.count
        try await Task.sleep(for: .milliseconds(200))
        guard cancellationCounter.count == afterCancel else {
            throw KestrelError.runtime("Frame callbacks continued after cancellation")
        }
        progress.set("request_after_cancel")
        // A new request must still work after cancelling a different connection.
        guard try await client.screenshot(format, credential: signer.token(for: .getScreenshot)) != nil else {
            throw KestrelError.runtime("Connection did not recover after cancellation")
        }
        var revokedTokenRejected = false
        var revocationSeconds = 0.0
        if let registration {
            progress.set("public_key_revocation")
            let token = try signer.token(for: .getScreenshot, lifetime: 120)
            guard try await client.screenshot(format, credential: token) != nil else {
                throw KestrelError.runtime("Pre-revocation request failed")
            }
            let started = ContinuousClock.now
            try registration.revoke()
            for _ in 0..<20 {
                do { _ = try await client.screenshot(format, credential: token) }
                catch EmulatorFrameConnectionError.rejected {
                    revokedTokenRejected = true
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            revocationSeconds = seconds(started.duration(to: .now))
            guard revokedTokenRejected, revocationSeconds < 15 else {
                throw KestrelError.runtime("Unexpired token remained accepted after public-key revocation")
            }
        }
        try reply(["status": "completed", "width": frame.width, "height": frame.height,
                   "native_registration_used": registration != nil,
                   "revoked_token_rejected": revokedTokenRejected, "revocation_seconds": revocationSeconds,
                   "rgba_sha256": SHA256.hash(data: frame.rgba).map { String(format: "%02x", $0) }.joined(),
                   "wrong_audience_rejected": true, "bounded_stream_frames": delivered,
                   "stream_seconds": seconds(stopped), "cancelled_after_frames": afterCancel,
                   "cancellation_seconds": seconds(cancellationDuration), "request_after_cancel": true])
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func writePNG(_ frame: PlayerFrame, path: String) throws {
        guard let provider = CGDataProvider(data: frame.rgba as CFData),
              let image = CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8,
                  bitsPerPixel: 32, bytesPerRow: frame.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                  UTType.png.identifier as CFString, 1, nil) else {
            throw KestrelError.runtime("Could not construct frame PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw KestrelError.runtime("PNG write failed") }
    }

    static func main() async {
        guard isatty(STDIN_FILENO) == 0, isatty(STDOUT_FILENO) == 0 else {
            fputs("This diagnostic requires controller pipes\n", stderr)
            exit(2)
        }
        guard #available(macOS 15, *) else { exit(2) }
        do { try await run() }
        catch {
            // Never serialize RPC details, credentials or signing material.
            var failure: [String: Any] = ["status": "failed", "stage": progress.stage,
                                          "error_type": String(describing: type(of: error))]
            if let safe = error as? EmulatorFrameConnectionError {
                failure["safe_code"] = String(describing: safe)
            }
            try? reply(failure)
            exit(1)
        }
    }
}
