import Foundation
import Crypto

/// AES-256-GCM sealing of everything the service stores (Untis access data,
/// device token, timetable snapshot, history). File format:
/// `NPS1` | 8-byte key id (SHA-256 prefix of the key) | nonce+ciphertext+tag.
/// The associated data binds a file to its purpose (device id), so files
/// cannot be swapped between devices unnoticed.
///
/// Key rotation: the keyring file holds one base64 key per line; the first
/// line encrypts, every line decrypts. A rewrite re-encrypts with the first.
public struct DataKeyring: Sendable {
    public struct Key: Sendable {
        let id: Data
        let key: SymmetricKey
    }
    public let keys: [Key]

    static let magic = Data("NPS1".utf8)

    public init(keys raw: [Data]) throws {
        guard !raw.isEmpty else { throw PushError.crypto("kein Schlüssel") }
        guard raw.allSatisfy({ $0.count == 32 }) else { throw PushError.crypto("Schlüssel müssen 32 Byte lang sein") }
        keys = raw.map { Key(id: Data(Crypto.SHA256.hash(data: $0).prefix(8)), key: SymmetricKey(data: $0)) }
    }

    /// Lines of base64 keys; blank lines and `#` comments are ignored.
    public init(fileContents text: String) throws {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        var raw: [Data] = []
        for line in lines {
            guard let data = Data(base64Encoded: line) else { throw PushError.crypto("Schlüsseldatei enthält kein Base64") }
            raw.append(data)
        }
        try self.init(keys: raw)
    }

    public static func load(path: String) throws -> DataKeyring {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        if let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o007 != 0 {
            throw PushError.crypto("Schlüsseldatei ist für alle lesbar (chmod 600)")
        }
        return try DataKeyring(fileContents: String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self))
    }

    /// A new random key as one base64 line (for `noty-push genkey`).
    public static func generateKeyLine() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    public func seal(_ plaintext: Data, context: String) throws -> Data {
        let current = keys[0]
        do {
            let box = try AES.GCM.seal(plaintext, using: current.key, authenticating: Data(("noty-push/1/" + context).utf8))
            guard let combined = box.combined else { throw PushError.crypto("Versiegeln fehlgeschlagen") }
            return Self.magic + current.id + combined
        } catch let error as PushError { throw error } catch { throw PushError.crypto("Versiegeln fehlgeschlagen") }
    }

    public func open(_ sealed: Data, context: String) throws -> Data {
        let bytes = Data(sealed)
        guard bytes.count > 12 + 12 + 16, bytes.prefix(4) == Self.magic else { throw PushError.crypto("unbekanntes Dateiformat") }
        let id = bytes.subdata(in: 4..<12)
        guard let key = keys.first(where: { $0.id == id }) else { throw PushError.crypto("Schlüssel nicht im Schlüsselbund (Rotation?)") }
        do {
            let box = try AES.GCM.SealedBox(combined: bytes.subdata(in: 12..<bytes.count))
            return try AES.GCM.open(box, using: key.key, authenticating: Data(("noty-push/1/" + context).utf8))
        } catch { throw PushError.crypto("Datei beschädigt oder verändert") }
    }

    /// True when `sealed` was not encrypted with the current key (rewrite it).
    public func needsRotation(_ sealed: Data) -> Bool {
        sealed.count > 12 && Data(sealed).subdata(in: 4..<12) != keys[0].id
    }
}

/// Random secrets and their stored form.
public enum Secrets {
    /// 32 random bytes, base64url without padding.
    public static func deviceSecret() -> String {
        base64URL(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    public static func hash(_ secret: String) -> String {
        Crypto.SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison of two equally long strings.
    public static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in x.indices { difference |= x[index] ^ y[index] }
        return difference == 0
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// HMAC-SHA1 for TOTP (RFC 6238) via swift-crypto; the app uses CryptoKit.
    public static func hmacSHA1(_ key: Data, _ message: Data) -> Data {
        Data(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }
}
