import CryptoKit
import Foundation

/// Only explicitly supported player methods may be authorized. Adding emulator control
/// methods requires reviewing their arguments and permissions separately.
public enum EmulatorRPCMethod: String, CaseIterable, Sendable {
    case getScreenshot, streamScreenshot, sendKey

    public var path: String { "/android.emulation.control.EmulatorController/" + rawValue }
}

/// Per-connection signing identity. The private key is never exported or persisted. Public
/// JWK removal on disconnect is the connection owner's responsibility, not token expiry alone.
public final class EmulatorTokenSigner {
    public static let issuer = "kestrel-native-player"
    public let keyID = UUID().uuidString.lowercased()
    private let key = P256.Signing.PrivateKey()

    public init() {}

    /// Caller must keep the returned bearer credential out of logs, files and diagnostics.
    public func token(for method: EmulatorRPCMethod, now: Date = Date(), lifetime: TimeInterval = 60) throws -> String {
        let seconds = now.timeIntervalSince1970
        // Bound NumericDate to a conservative representable range before converting to Int.
        // Requiring whole seconds avoids accidentally issuing an immediately expired token.
        guard seconds.isFinite, seconds >= 1, seconds <= 253_402_300_000,
              lifetime.isFinite, lifetime >= 1, lifetime <= 120, lifetime.rounded(.down) == lifetime else {
            throw KestrelError.invalid("Invalid emulator credential time or lifetime")
        }
        let issued = Int(seconds.rounded(.down))
        let header = try Self.encoded(["alg": "ES256", "kid": keyID])
        let claims = try Self.encoded([
            "iss": Self.issuer,
            "aud": [method.path],
            "iat": issued - 1,
            "exp": issued + Int(lifetime)
        ] as [String: Any])
        let signingInput = header + "." + claims
        let signature = try key.signature(for: Data(signingInput.utf8))
        return signingInput + "." + Self.base64URL(signature.rawRepresentation)
    }

    public func publicKeySet() throws -> Data {
        let bytes = key.publicKey.x963Representation
        guard bytes.count == 65, bytes.first == 4 else {
            throw KestrelError.runtime("Unexpected P-256 public key representation")
        }
        let jwk: [String: String] = [
            "kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": keyID,
            "x": Self.base64URL(bytes.subdata(in: 1..<33)),
            "y": Self.base64URL(bytes.subdata(in: 33..<65))
        ]
        return try JSONSerialization.data(withJSONObject: ["keys": [jwk]], options: [.sortedKeys])
    }

    public static func accessPolicy() throws -> Data {
        let rule: [String: Any] = ["iss": issuer, "allowed": [String](),
                                   "protected": EmulatorRPCMethod.allCases.map(\.path)]
        return try JSONSerialization.data(withJSONObject: ["unprotected": [String](), "allowlist": [rule]],
                                          options: [.sortedKeys])
    }

    private static func encoded(_ object: [String: Any]) throws -> String {
        base64URL(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
