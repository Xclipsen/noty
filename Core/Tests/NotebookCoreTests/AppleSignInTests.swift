import Foundation
import XCTest
@testable import NotebookCore

final class AppleSignInTests: XCTestCase {
    private struct Counter: RandomNumberGenerator {
        var value: UInt64 = 0
        mutating func next() -> UInt64 { value &+= 1; return value }
    }
    private struct User: Decodable, Sendable, Equatable { var id: String; var name: String; var token: String?; var apple: Bool? }

    func testNonceIs32BytesOfLowercaseHexAndFresh() {
        let nonce = AppleSignIn.makeNonce()
        XCTAssertEqual(nonce.count, 64)
        XCTAssertNotNil(nonce.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        XCTAssertNotEqual(nonce, AppleSignIn.makeNonce())
        var a = Counter(), b = Counter()
        XCTAssertEqual(AppleSignIn.makeNonce(using: &a), AppleSignIn.makeNonce(using: &b), "deterministic with the same source")
    }

    func testHexAndHashedNonce() {
        XCTAssertEqual(AppleSignIn.hex([0x00, 0x0f, 0xa5, 0xff]), "000fa5ff")
        // sha256("abc"): the server compares the token's nonce with sha256(raw) as hex.
        XCTAssertEqual(AppleSignIn.hashedNonce("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let raw = AppleSignIn.makeNonce()
        XCTAssertEqual(AppleSignIn.hashedNonce(raw), SHA256.hexDigest(Data(raw.utf8)))
        XCTAssertNotEqual(AppleSignIn.hashedNonce(raw), raw)
    }

    func testIdentityTokenShape() {
        XCTAssertEqual(AppleSignIn.identityToken(Data("eyJh.eyJz.c2ln-_".utf8)), "eyJh.eyJz.c2ln-_")
        for bad in ["", "a.b", "a..c", "a.b.c.d", "a.b.c=", "a b.c.d", "ä.b.c"] {
            XCTAssertNil(AppleSignIn.identityToken(Data(bad.utf8)), bad)
        }
        XCTAssertNil(AppleSignIn.identityToken(nil))
        XCTAssertNil(AppleSignIn.identityToken(Data(("a." + String(repeating: "b", count: 16_384) + ".c").utf8)))
    }

    func testNameOnlyWhenAppleSendsOne() {
        XCTAssertEqual(AppleSignIn.suggestedName(givenName: "  Leon \n"), "Leon")
        XCTAssertNil(AppleSignIn.suggestedName(givenName: nil))
        XCTAssertNil(AppleSignIn.suggestedName(givenName: "   "))
        XCTAssertEqual(AppleSignIn.suggestedName(givenName: String(repeating: "x", count: 100))?.count, 64)
        XCTAssertEqual(AppleSignIn.loginBody(identityToken: "t", nonce: "n", givenName: "Leon"),
                       ["identityToken": .string("t"), "nonce": .string("n"), "name": .string("Leon")])
        XCTAssertEqual(AppleSignIn.loginBody(identityToken: "t", nonce: "n", givenName: nil),
                       ["identityToken": .string("t"), "nonce": .string("n")], "later sign-ins carry no name and no create flag")
        XCTAssertEqual(AppleSignIn.linkBody(identityToken: "t", nonce: "n"), ["identityToken": .string("t"), "nonce": .string("n")])
    }

    func testResponses() throws {
        let created = try JSONDecoder().decode(AppleLoginResponse<User>.self, from: Data(#"{"user":{"id":"u","name":"apple-a1b2c3","token":"tok"},"created":true}"#.utf8))
        XCTAssertTrue(created.created)
        XCTAssertEqual(created.user, User(id: "u", name: "apple-a1b2c3", token: "tok", apple: nil))
        let existing = try JSONDecoder().decode(AppleLoginResponse<User>.self, from: Data(#"{"user":{"id":"u","name":"Leon","apple":true}}"#.utf8))
        XCTAssertFalse(existing.created)
        XCTAssertEqual(existing.user.apple, true)
        XCTAssertThrowsError(try JSONDecoder().decode(AppleLoginResponse<User>.self, from: Data(#"{"created":true}"#.utf8)))

        let linked = try JSONDecoder().decode(AppleLinkResponse<User>.self, from: Data(#"{"user":{"id":"u","name":"Leon","apple":true},"apple":true}"#.utf8))
        XCTAssertTrue(linked.apple)
        XCTAssertEqual(linked.user?.id, "u")
        let unlinked = try JSONDecoder().decode(AppleLinkResponse<User>.self, from: Data(#"{"apple":false}"#.utf8))
        XCTAssertFalse(unlinked.apple)
        XCTAssertNil(unlinked.user)
    }

    func testCancelIsSilentOtherFailuresAreGerman() {
        XCTAssertNil(AppleSignInFailure.message(code: AppleSignInFailure.canceled))
        for code in [1000, 1002, 1003, 1004, 1005, 1006, 42] {
            let message = AppleSignInFailure.message(code: code)
            XCTAssertNotNil(message)
            XCTAssertFalse(message!.isEmpty)
        }
    }
    func testExpiredSessionOrForeignDataNeverCreatesAnAccountSilently() {
        XCTAssertTrue(AppleLoginPlan.mayCreate(sessionExpired: false, foreignPendingCount: 0))
        XCTAssertFalse(AppleLoginPlan.mayCreate(sessionExpired: true, foreignPendingCount: 0))
        XCTAssertFalse(AppleLoginPlan.mayCreate(sessionExpired: false, foreignPendingCount: 3))
        XCTAssertEqual(AppleSignIn.loginBody(identityToken: "t", nonce: "n", givenName: nil, create: false),
                       ["identityToken": .string("t"), "nonce": .string("n"), "create": .bool(false)])
        XCTAssertEqual(AppleSignIn.loginBody(identityToken: "t", nonce: "n", givenName: nil, create: true),
                       ["identityToken": .string("t"), "nonce": .string("n")])
        guard case .explainLinking(let text) = AppleLoginPlan.unknown(sessionExpired: true, accountName: "Leon", foreignPendingCount: 2) else {
            return XCTFail("expired session must explain linking")
        }
        XCTAssertTrue(text.contains("„Leon“"))
        XCTAssertTrue(text.contains("Apple verknüpfen"))
        XCTAssertTrue(text.contains("kein neues Konto"))
        guard case .confirmCreation(_, let message) = AppleLoginPlan.unknown(sessionExpired: false, accountName: nil, foreignPendingCount: 1) else {
            return XCTFail("foreign data must ask")
        }
        XCTAssertTrue(message.contains("1 Markierung"))
    }

    func testOlderRefreshDoesNotOverwriteALaterAccountChange() {
        var gate = AccountUpdateGate()
        let refresh = gate.begin()
        XCTAssertTrue(gate.isCurrent(refresh))
        gate.changed() // Apple linked while the refresh was under way
        XCTAssertFalse(gate.isCurrent(refresh))
        XCTAssertTrue(gate.isCurrent(gate.begin()))
    }

    func testImmediateCancelWithoutAppleIDGivesAHint() {
        XCTAssertNil(AppleSignInFailure.message(code: 1001, elapsed: 4, underlyingDomain: nil, underlyingCode: nil), "the user closed the sheet")
        XCTAssertEqual(AppleSignInFailure.message(code: 1001, elapsed: 0.1, underlyingDomain: nil, underlyingCode: nil), AppleSignInFailure.noAppleIDHint)
        XCTAssertEqual(AppleSignInFailure.message(code: 1001, elapsed: 5, underlyingDomain: "AKAuthenticationError", underlyingCode: -7026),
                       AppleSignInFailure.noAppleIDHint)
        XCTAssertEqual(AppleSignInFailure.message(code: 1004, elapsed: 0.1, underlyingDomain: nil, underlyingCode: nil),
                       AppleSignInFailure.message(code: 1004))
    }
}
