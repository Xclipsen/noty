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

    /// `POST /api/apple/login`. `create: true` leaves the flag out (the
    /// server may open a new account); `false` sends `create: false`, so an
    /// unknown Apple ID is answered with 401 `apple_unknown` instead
    /// (`AppleLoginPlan`).
    public static func loginBody(identityToken: String, nonce: String, givenName: String?, create: Bool = true) -> [String: LawJSON] {
        var body: [String: LawJSON] = ["identityToken": .string(identityToken), "nonce": .string(nonce)]
        if let name = suggestedName(givenName: givenName) { body["name"] = .string(name) }
        if !create { body["create"] = .bool(false) }
        return body
    }

    /// The server's code for an Apple ID that no account is linked to (401).
    public static let unknownCode = "apple_unknown"

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

/// When „Mit Apple anmelden“ may open a new account. A new account must not
/// appear silently while this iPad still belongs to another one: when the
/// session of a known account expired (the user wants back into it), and
/// when markings of another account are not transferred yet.
public enum AppleLoginPlan {
    /// The first request: `create: false` in both situations above.
    public static func mayCreate(sessionExpired: Bool, foreignPendingCount: Int) -> Bool {
        !sessionExpired && foreignPendingCount == 0
    }

    public enum Unknown: Equatable, Sendable {
        /// Expired session: explain linking, create nothing.
        case explainLinking(String)
        /// Other account's data waits: ask before creating an account.
        case confirmCreation(title: String, message: String)
    }

    /// What to do when the server answers `apple_unknown` to `create: false`.
    public static func unknown(sessionExpired: Bool, accountName: String?, foreignPendingCount: Int) -> Unknown {
        if sessionExpired {
            let name = accountName.map { "„\($0)“" } ?? "dem bisherigen Konto"
            return .explainLinking("Mit dieser Apple-ID ist noch kein noty-Konto verknüpft; es wurde kein neues Konto angelegt. Bitte als \(name) mit Benutzername und Passwort anmelden und danach unter „Konto“ „Apple verknüpfen“ wählen.")
        }
        let count = foreignPendingCount == 1 ? "1 Markierung" : "\(foreignPendingCount) Markierungen"
        return .confirmCreation(title: "Neues noty-Konto anlegen?",
            message: "Mit dieser Apple-ID ist noch kein noty-Konto verknüpft. Auf diesem iPad liegen \(count) eines anderen Kontos, die noch nicht übertragen sind; sie bleiben bei jenem Konto und werden nicht ins neue übernommen. Gehört diese Apple-ID zu einem bestehenden Konto, dort mit Passwort anmelden und Apple verknüpfen.")
    }
}

/// Orders account updates from overlapping requests: a slower refresh may
/// not overwrite what a later local change (Apple linked, signed in) wrote.
public struct AccountUpdateGate: Sendable {
    public private(set) var generation = 0
    public init() {}
    /// Before a request whose answer will replace account fields.
    public func begin() -> Int { generation }
    /// After every local change of the account.
    public mutating func changed() { generation &+= 1 }
    /// The answer of the request started at `token` may still be applied.
    public func isCurrent(_ token: Int) -> Bool { token == generation }
}

/// German text for a failed Apple sheet; `nil` means the user cancelled and
/// nothing is shown. Codes as in `ASAuthorizationError.Code`.
public enum AppleSignInFailure {
    public static let canceled = 1001
    /// A cancel faster than this cannot have been the user's: iOS ended the
    /// request without a sheet, typically because no Apple ID is signed in.
    public static let immediateCancel: Double = 0.8
    /// `AKAuthenticationError` codes iOS reports underneath when no Apple ID
    /// can be used on this device (seen as underlying error; not documented).
    public static let notSignedInUnderlyingCodes: Set<Int> = [-7026, -7027]
    public static let noAppleIDHint = "Es erschien kein Apple-Fenster. Ist auf diesem iPad unter Einstellungen eine Apple-ID angemeldet? Danach erneut versuchen."

    /// Like `message(code:)`, but a cancel that the user cannot have made
    /// (immediate, or with an underlying not-signed-in error) gives a hint.
    public static func message(code: Int, elapsed: Double, underlyingDomain: String?, underlyingCode: Int?) -> String? {
        if underlyingDomain == "AKAuthenticationError", let underlyingCode, notSignedInUnderlyingCodes.contains(underlyingCode) {
            return noAppleIDHint
        }
        if code == canceled { return elapsed < immediateCancel ? noAppleIDHint : nil }
        return message(code: code)
    }

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
