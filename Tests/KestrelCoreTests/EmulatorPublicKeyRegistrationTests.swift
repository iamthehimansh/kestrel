import Foundation
import XCTest
@testable import KestrelCore

final class EmulatorPublicKeyRegistrationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("player-public-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testPublishesOnlyPublicMaterialAndRevokesOwnFile() throws {
        let signer = EmulatorTokenSigner()
        let unrelated = directory.appendingPathComponent("another-client.jwk")
        try Data("keep".utf8).write(to: unrelated)
        let registration = try EmulatorPublicKeyRegistration(directory: directory, signer: signer)
        let file = directory.appendingPathComponent(registration.fileName)
        XCTAssertEqual(try Data(contentsOf: file), try signer.publicKeySet())
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let keys = try XCTUnwrap(object["keys"] as? [[String: Any]])
        XCTAssertNil(keys.first?["d"])
        try registration.revoke()
        try registration.revoke()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
    }

    func testDuplicateRegistrationDoesNotOverwrite() throws {
        let signer = EmulatorTokenSigner()
        let first = try EmulatorPublicKeyRegistration(directory: directory, signer: signer)
        defer { try? first.revoke() }
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertThrowsError(try EmulatorPublicKeyRegistration(directory: directory, signer: signer))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), before)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(first.fileName)), try signer.publicKeySet())
    }

    func testRejectsSymlinkDirectoryAndUnsafePermissions() throws {
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertThrowsError(try EmulatorPublicKeyRegistration(directory: alias, signer: EmulatorTokenSigner()))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try EmulatorPublicKeyRegistration(directory: directory, signer: EmulatorTokenSigner()))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try EmulatorPublicKeyRegistration(directory: URL(string: "https://example.com/keys")!,
                                                             signer: EmulatorTokenSigner()))
    }

    func testRevocationRefusesReplacementFile() throws {
        let registration = try EmulatorPublicKeyRegistration(directory: directory, signer: EmulatorTokenSigner())
        let original = directory.appendingPathComponent(registration.fileName)
        let moved = directory.appendingPathComponent("original-moved.jwk")
        try FileManager.default.moveItem(at: original, to: moved)
        let replacement = Data("replacement owned by someone else".utf8)
        try replacement.write(to: original)
        XCTAssertThrowsError(try registration.revoke())
        XCTAssertEqual(try Data(contentsOf: original), replacement)
        try FileManager.default.removeItem(at: original)
        try FileManager.default.moveItem(at: moved, to: original)
        try registration.revoke()
    }

    func testPinnedDirectoryPreventsDeletingThroughReplacedPath() throws {
        let registration = try EmulatorPublicKeyRegistration(directory: directory, signer: EmulatorTokenSigner())
        let moved = directory.appendingPathExtension("moved")
        defer { try? FileManager.default.removeItem(at: moved) }
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let replacement = directory.appendingPathComponent(registration.fileName)
        try Data("keep".utf8).write(to: replacement)
        try registration.revoke()
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved.appendingPathComponent(registration.fileName).path))
        XCTAssertEqual(try Data(contentsOf: replacement), Data("keep".utf8))
    }

    func testReleaseAutomaticallyRevokesAndAlreadyMissingFileIsSafe() throws {
        var registration: EmulatorPublicKeyRegistration? = try EmulatorPublicKeyRegistration(directory: directory,
                                                                                             signer: EmulatorTokenSigner())
        let file = directory.appendingPathComponent(try XCTUnwrap(registration?.fileName))
        registration = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let missing = try EmulatorPublicKeyRegistration(directory: directory, signer: EmulatorTokenSigner())
        try FileManager.default.removeItem(at: directory.appendingPathComponent(missing.fileName))
        XCTAssertNoThrow(try missing.revoke())
    }
}
