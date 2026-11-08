import Foundation
import XCTest
import NotebookCore
@testable import NotyPushKit

final class SealingStoreTests: XCTestCase {
    func testSealRoundTripBindsContextAndDetectsTampering() throws {
        let keyring = testKeyring()
        let plain = Data("geheime Freigabe".utf8)
        let sealed = try keyring.seal(plain, context: "device/a")
        XCTAssertEqual(try keyring.open(sealed, context: "device/a"), plain)
        XCTAssertNil(sealed.range(of: plain), "Klartext darf nicht in der Datei stehen")
        XCTAssertThrowsError(try keyring.open(sealed, context: "device/b"))
        var tampered = sealed; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try keyring.open(tampered, context: "device/a"))
        XCTAssertThrowsError(try keyring.open(Data("NPS1xx".utf8), context: "device/a"))
    }

    func testKeyRotationDecryptsOldAndEncryptsWithNewKey() throws {
        let old = try DataKeyring(keys: [Data(repeating: 1, count: 32)])
        let sealed = try old.seal(Data("x".utf8), context: "c")
        let rotated = try DataKeyring(fileContents: "# neu zuerst\n\(Data(repeating: 2, count: 32).base64EncodedString())\n\n\(Data(repeating: 1, count: 32).base64EncodedString())\n")
        XCTAssertEqual(try rotated.open(sealed, context: "c"), Data("x".utf8))
        XCTAssertTrue(rotated.needsRotation(sealed))
        XCTAssertFalse(rotated.needsRotation(try rotated.seal(Data("x".utf8), context: "c")))
        let only = try DataKeyring(keys: [Data(repeating: 2, count: 32)])
        XCTAssertThrowsError(try only.open(sealed, context: "c"))
        XCTAssertThrowsError(try DataKeyring(fileContents: "kurz"))
        XCTAssertThrowsError(try DataKeyring(fileContents: Data(repeating: 1, count: 16).base64EncodedString()))
        XCTAssertEqual(Data(base64Encoded: DataKeyring.generateKeyLine())?.count, 32)
    }

    func testWorldReadableKeyFileIsRejected() throws {
        let dir = temporaryDirectory()
        let path = dir + "/data.key"
        try (DataKeyring.generateKeyLine() + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        chmod(path, 0o644)
        XCTAssertThrowsError(try DataKeyring.load(path: path))
        chmod(path, 0o600)
        XCTAssertNoThrow(try DataKeyring.load(path: path))
    }

    func testStoreWritesPrivateSealedFilesAndSkipsUnreadableOnes() async throws {
        let dir = temporaryDirectory()
        let clock = Clock(at(2026, 11, 9, 10))
        let source = StubSource(); source.lessons = [lesson(1, at(2026, 11, 10, 8))]
        let service = try makeService(dir: dir, source: source, sender: MockSender(), clock: clock)
        let result = try await service.register(registration())
        let file = dir + "/devices/\(result.deviceID).sealed"
        let attributes = try FileManager.default.attributesOfItem(atPath: file)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttributes = try FileManager.default.attributesOfItem(atPath: dir + "/devices")
        XCTAssertEqual((dirAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: file))
        for secret in [rfcKey, "max.muster", fakeToken, "Deutsch"] {
            XCTAssertNil(bytes.range(of: Data(secret.utf8)), "\(secret) im Klartext gespeichert")
        }
        // Reload: the same device comes back, the setup is validated again.
        let store = try DeviceStore(dataDirectory: dir, keyring: testKeyring())
        let loaded = store.loadAll()
        XCTAssertEqual(loaded.records.map(\.id), [result.deviceID])
        XCTAssertEqual(loaded.records.first?.setup, setup())
        // A damaged file is reported and left in place, never deleted.
        let broken = UUID().uuidString.lowercased()
        try Data("NPS1-kaputt-kaputt-kaputt-kaputt-kaputt".utf8).write(to: URL(fileURLWithPath: dir + "/devices/\(broken).sealed"))
        let again = store.loadAll()
        XCTAssertEqual(again.records.count, 1)
        XCTAssertEqual(again.problems.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/devices/\(broken).sealed"))
        // Another key cannot read the files.
        let foreign = try DeviceStore(dataDirectory: dir, keyring: try DataKeyring(keys: [Data(repeating: 9, count: 32)]))
        XCTAssertEqual(foreign.loadAll().records.count, 0)
        // Temporary leftovers are removed; invalid ids are refused.
        FileManager.default.createFile(atPath: dir + "/devices/.tmp-x", contents: Data())
        store.removeTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/devices/.tmp-x"))
        XCTAssertThrowsError(try store.load("../etc/passwd"))
        XCTAssertThrowsError(try store.delete("NICHT-KLEIN"))
    }

    func testSecretsHashAndCompare() {
        let secret = Secrets.deviceSecret()
        XCTAssertGreaterThanOrEqual(secret.count, 43)
        XCTAssertFalse(secret.contains("=") || secret.contains("+") || secret.contains("/"))
        XCTAssertNotEqual(secret, Secrets.deviceSecret())
        XCTAssertTrue(Secrets.equal(Secrets.hash(secret), Secrets.hash(secret)))
        XCTAssertFalse(Secrets.equal(Secrets.hash(secret), Secrets.hash(secret + "x")))
        XCTAssertFalse(Secrets.equal("a", "ab"))
    }

    func testHMACSHA1MatchesRFC6238ThroughCoreTOTP() {
        let secret = TOTP.base32Decode(rfcKey)!
        XCTAssertEqual(TOTP.code(secret: secret, at: Date(timeIntervalSince1970: 59), hmacSHA1: Secrets.hmacSHA1), "287082")
        XCTAssertEqual(TOTP.code(secret: secret, at: Date(timeIntervalSince1970: 1_111_111_109), hmacSHA1: Secrets.hmacSHA1), "081804")
        XCTAssertEqual(TOTP.code(secret: secret, at: Date(timeIntervalSince1970: 20_000_000_000), hmacSHA1: Secrets.hmacSHA1), "353130")
    }
}
