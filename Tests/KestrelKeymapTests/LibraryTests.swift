import XCTest
@testable import KestrelKeymap

final class LibraryTests: XCTestCase {
    var tmp: URL!
    var lib: KeymapLibrary!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-lib-\(UUID().uuidString)")
        let bundled = tmp.appendingPathComponent("bundled")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let preset = Keymap(name: "Preset", package: "com.example.game", controls: [.tap(TapControl(key: "F", at: NPoint(0.5, 0.5)))])
        try preset.encoded().write(to: bundled.appendingPathComponent("game.json"))
        try Data("not json".utf8).write(to: bundled.appendingPathComponent("broken.json"))
        lib = KeymapLibrary(userDir: tmp.appendingPathComponent("user"), bundledDirs: [bundled])
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testListsBundledAndSkipsBroken() {
        XCTAssertEqual(lib.all().map(\.id), ["game"])
        XCTAssertFalse(lib.all()[0].isUser)
    }

    func testResolveByIdPackageAndMissing() throws {
        XCTAssertEqual(try lib.resolve("game").keymap.name, "Preset")
        XCTAssertEqual(try lib.resolve("com.example.game").id, "game")
        XCTAssertEqual(lib.forPackage("com.example.game")?.id, "game")
        XCTAssertThrowsError(try lib.resolve("nope"))
    }

    func testUserCopyOverridesAndDeleteRestores() throws {
        var km = try lib.resolve("game").keymap
        km.name = "Mine"
        try lib.save(km, id: "game")
        XCTAssertEqual(try lib.resolve("game").keymap.name, "Mine")
        XCTAssertTrue(try lib.resolve("game").isUser)
        try lib.deleteUser(id: "game")
        XCTAssertEqual(try lib.resolve("game").keymap.name, "Preset", "bundled preset shows again")
    }

    func testSaveRejectsBadIdAndInvalidKeymap() {
        let ok = Keymap(name: "x", controls: [])
        XCTAssertThrowsError(try lib.save(ok, id: "Bad Name"))
        XCTAssertThrowsError(try lib.save(ok, id: "../escape"))
        let bad = Keymap(name: "x", controls: [.tap(TapControl(key: "Nope", at: NPoint(0.5, 0.5)))])
        XCTAssertThrowsError(try lib.save(bad, id: "bad"))
    }

    func testFreeIDAndSlug() throws {
        XCTAssertEqual(lib.freeID("game"), "game-2")
        XCTAssertEqual(lib.freeID("New Game!"), "new-game")
        XCTAssertEqual(KeymapLibrary.slug("  BGMI / PUBG  "), "bgmi-pubg")
        XCTAssertEqual(KeymapLibrary.slug("!!!"), "keymap")
    }
}
