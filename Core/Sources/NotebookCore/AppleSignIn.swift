import Foundation

/// „Mit Apple anmelden“ (docs/APPLE-LOGIN.md): the platform-independent parts.
/// Apple is only another way into a noty account; nothing from Apple is kept
/// on the iPad. The identity token goes straight to the account server, which
/// checks it completely; the app never reads it.
public enum AppleSignIn {
    /// Random bytes per attempt (contract: 32).
    public static let nonceByteCount = 32
    /// Identity tokens are a few hundred bytes to a few KB; anything larger is not one.
    public static let maximumTokenLength = 16_384
    /// Apple's first name is a suggestion for the account name; the server
    /// decides what is free and valid.
    public static let maximumNameLength = 64

    /// The raw nonce: `nonceByteCount` bytes as 64 lowercase hex characters.
    /// It goes to the server; Apple only ever sees `hashedNonce(raw)`.
    public static func makeNonce<G: RandomNumberGenerator>(using generator: inout G) -> String {
        hex((0..<nonceByteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// `SystemRandomNumberGenerator` is the platform's cryptographic source.
    public static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return makeNonce(using: &generator)
    }

    /// What the identity token carries as `nonce`: `sha256(raw)` as lowercase hex.
    public static func hashedNonce(_ raw: String) -> String { SHA256.hexDigest(Data(raw.utf8)) }

    public static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for byte in bytes { out.append(digits[Int(byte >> 4)]); out.append(digits[Int(byte & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// The token Apple returns as UTF-8 data; `nil` unless it looks like a
    /// compact JWS (three non-empty base64url parts). Its content stays unread.
    public static func identityToken(_ data: Data?) -> String? {
        guard let data, !data.isEmpty, data.count <= maximumTokenLength,
              let token = String(data: data, encoding: .utf8) else { return nil }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(allowed.contains) }) else { return nil }
        return token
    }

    /// Apple sends the name only on the very first authorisation for this app;
    /// later attempts have none, and then nothing is sent.
    public static func suggestedName(givenName: String?) -> String? {
        guard let name = givenName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return String(name.prefix(maximumNameLength))
    }

    /// `POST /api/apple/login`. `create` is left out: the app may open a new
    /// account (only the admin panel sends `create: false`).
    public static func loginBody(identityToken: String, nonce: String, givenName: String?) -> [String: LawJSON] {
        var body: [String: LawJSON] = ["identityToken": .string(identityToken), "nonce": .string(nonce)]
        if let name = suggestedName(givenName: givenName) { body["name"] = .string(name) }
        return body
    }

    /// `POST /api/apple/link`: no name, the account already has one.
    public static func linkBody(identityToken: String, nonce: String) -> [String: LawJSON] {
        ["identityToken": .string(identityToken), "nonce": .string(nonce)]
    }
}

/// `POST /api/apple/login`: like `/api/login`, plus `created` for a new account.
public struct AppleLoginResponse<User: Decodable & Sendable>: Decodable, Sendable {
    public var user: User
    public var created: Bool
    private enum CodingKeys: String, CodingKey { case user, created }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        user = try c.decode(User.self, forKey: .user)
        created = try c.decodeIfPresent(Bool.self, forKey: .created) ?? false
    }
}

/// `POST /api/apple/link` (`apple: true`) and `DELETE /api/apple` (`apple: false`).
/// The link answer also carries the account; unlinking does not.
public struct AppleLinkResponse<User: Decodable & Sendable>: Decodable, Sendable {
    public var user: User?
    public var apple: Bool
}

/// German text for a failed Apple sheet; `nil` means the user cancelled and
/// nothing is shown. Codes as in `ASAuthorizationError.Code`.
public enum AppleSignInFailure {
    public static let canceled = 1001
    public static func message(code: Int) -> String? {
        switch code {
        case canceled: return nil
        case 1002: return "Apple hat eine ungültige Antwort geliefert. Bitte erneut versuchen."
        case 1003: return "Apple konnte die Anmeldung nicht bearbeiten. Bitte erneut versuchen."
        case 1004: return "Die Anmeldung mit Apple ist fehlgeschlagen. Bitte erneut versuchen."
        case 1005: return "Die Anmeldung mit Apple braucht eine Bestätigung auf diesem iPad."
        default: return "Mit Apple anmelden ist gerade nicht möglich. Ist auf diesem iPad eine Apple-ID angemeldet?"
        }
    }
}
