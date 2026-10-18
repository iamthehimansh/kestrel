import CryptoKit
import Foundation
import XCTest
@testable import KestrelCore

final class EmulatorTokenTests: XCTestCase {
    private func decode(_ component: String) throws -> Data {
        var base64 = component.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return try XCTUnwrap(Data(base64Encoded: base64))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTokenSignatureClaimsAndHeaderMatchEmulatorContract() throws {
        let signer = EmulatorTokenSigner()
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let token = try signer.token(for: .streamScreenshot, now: now, lifetime: 60)
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let header = try object(decode(parts[0]))
        let claims = try object(decode(parts[1]))
        XCTAssertEqual(header["alg"] as? String, "ES256")
        XCTAssertNil(header["typ"], "Emulator rejects the optional typ header")
        XCTAssertEqual(header["kid"] as? String, signer.keyID)
        XCTAssertEqual(claims["iss"] as? String, EmulatorTokenSigner.issuer)
        XCTAssertEqual(claims["aud"] as? [String], [EmulatorRPCMethod.streamScreenshot.path])
        XCTAssertEqual(claims["iat"] as? Int, 1_899_999_999)
        XCTAssertEqual(claims["exp"] as? Int, 1_900_000_060)

        let jwks = try object(signer.publicKeySet())
        let keys = try XCTUnwrap(jwks["keys"] as? [[String: Any]])
        XCTAssertEqual(keys.count, 1)
        let jwk = keys[0]
        XCTAssertEqual(jwk["kty"] as? String, "EC")
        XCTAssertEqual(jwk["crv"] as? String, "P-256")
        XCTAssertEqual(jwk["kid"] as? String, signer.keyID)
        XCTAssertNil(jwk["d"], "Private key material must never be exported")
        var publicBytes = Data([4])
        publicBytes.append(try decode(XCTUnwrap(jwk["x"] as? String)))
        publicBytes.append(try decode(XCTUnwrap(jwk["y"] as? String)))
        let publicKey = try P256.Signing.PublicKey(x963Representation: publicBytes)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        let signed = Data((parts[0] + "." + parts[1]).utf8)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: signed))
        XCTAssertFalse(publicKey.isValidSignature(signature, for: Data((parts[0] + ".tampered").utf8)))
    }

    func testEveryTokenHasOnlyTheRequestedMethodAudience() throws {
        let signer = EmulatorTokenSigner()
        for method in EmulatorRPCMethod.allCases {
            let parts = try signer.token(for: method).split(separator: ".")
            let claims = try object(decode(String(parts[1])))
            XCTAssertEqual(claims["aud"] as? [String], [method.path])
        }
        XCTAssertNil(EmulatorRPCMethod(rawValue: "deleteSnapshot"))
        XCTAssertNil(EmulatorRPCMethod(rawValue: "../../execute"))
    }

    func testLifetimeAndTimeBoundsRejectInvalidClaims() throws {
        let signer = EmulatorTokenSigner()
        for lifetime in [0, -1, 121, Double.infinity, Double.nan] {
            XCTAssertThrowsError(try signer.token(for: .getScreenshot, lifetime: lifetime))
        }
        for seconds in [Double.infinity, Double.nan, -1, 0, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try signer.token(for: .getScreenshot, now: Date(timeIntervalSince1970: seconds)))
        }
    }

    func testIndependentSessionsUseDifferentKeys() throws {
        let first = EmulatorTokenSigner()
        let second = EmulatorTokenSigner()
        XCTAssertNotEqual(first.keyID, second.keyID)
        XCTAssertNotEqual(try first.publicKeySet(), try second.publicKeySet())
    }

    func testAccessPolicyRequiresAuthenticationAndUsesExactMethodPaths() throws {
        let policy = try object(EmulatorTokenSigner.accessPolicy())
        XCTAssertEqual(policy["unprotected"] as? [String], [])
        let rules = try XCTUnwrap(policy["allowlist"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0]["iss"] as? String, EmulatorTokenSigner.issuer)
        XCTAssertEqual(rules[0]["allowed"] as? [String], [])
        XCTAssertEqual(rules[0]["protected"] as? [String], EmulatorRPCMethod.allCases.map(\.path))
        XCTAssertFalse(try String(decoding: EmulatorTokenSigner.accessPolicy(), as: UTF8.self).contains(".*"))
    }
}
