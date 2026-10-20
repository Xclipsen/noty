import Foundation

/// The app's own `embedded.mobileprovision` is a CMS signed blob whose content
/// is an XML property list. Only that plist is read; the signature is not checked.
public enum SigningProfile {
    public static func expirationDate(_ data: Data) -> Date? {
        guard data.count <= 2_000_000, let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], options: [], format: nil)
                as? [String: Any] else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    /// One fixed local reminder a day before expiry, or soon when that moment has passed.
    public static func reminderDate(expiration: Date, now: Date = Date()) -> Date? {
        guard expiration > now else { return nil }
        return max(now.addingTimeInterval(60), expiration.addingTimeInterval(-24 * 3600))
    }
}
