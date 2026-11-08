import Foundation

/// When the server asks WebUntis (hours of the device's wall clock, the
/// registration's `timeZone`; quiet hours use the same clock).
/// Default: hourly 5:00–20:59 on weekdays, every two hours 8–20 on weekends,
/// nothing from 21:00 to 4:59 (user decision 08.11.2026).
public struct PollScheduleConfig: Codable, Equatable, Sendable {
    public var weekdayHours: [Int] = Array(5...20)
    public var weekendHours: [Int] = [8, 10, 12, 14, 16, 18, 20]
    /// Each device polls at a fixed minute 0..<spreadMinutes after the full
    /// hour (derived from its id), so several devices do not hit WebUntis at once.
    public var spreadMinutes = 15

    public init() {}

    public var isValid: Bool {
        let hours = 0...23
        return weekdayHours.allSatisfy(hours.contains) && weekendHours.allSatisfy(hours.contains)
            && !(weekdayHours.isEmpty && weekendHours.isEmpty) && (1...59).contains(spreadMinutes)
    }

    private enum CodingKeys: String, CodingKey { case weekdayHours, weekendHours, spreadMinutes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PollScheduleConfig()
        weekdayHours = try c.decodeIfPresent([Int].self, forKey: .weekdayHours) ?? d.weekdayHours
        weekendHours = try c.decodeIfPresent([Int].self, forKey: .weekendHours) ?? d.weekendHours
        spreadMinutes = try c.decodeIfPresent(Int.self, forKey: .spreadMinutes) ?? d.spreadMinutes
    }
}

/// Non-secret configuration (`/etc/noty-push/config.json`). Secrets (data
/// key, APNs .p8) are separate files, read via systemd `LoadCredential`.
public struct PushConfig: Codable, Equatable, Sendable {
    public var listenHost = "127.0.0.1"
    public var port = 8795
    public var dataDirectory = "/var/lib/noty-push"
    /// Relative paths are resolved in `$CREDENTIALS_DIRECTORY` (systemd), else next to the config file.
    public var dataKeyFile = "data.key"
    public var apnsKeyFile = "apns.p8"
    public var apnsKeyID = ""
    public var teamID = ""
    /// APNs topics = CFBundleIdentifier of the signed app (docs/PUSH.md).
    public var allowedBundleIDs: [String] = []
    public var maxDevices = 5
    /// The app sends this string to confirm the user accepted the consent text.
    public var consentVersion = "webuntis-push-1"
    /// Days from today that are compared (today included).
    public var windowDays = 14
    public var schedule = PollScheduleConfig()
    public var curlPath = "/usr/bin/curl"
    /// Registration attempts per hour and address (IPv6: per /64 network).
    public var registrationsPerHourPerIP = 5
    /// Successful registrations per day, whole service.
    public var registrationsPerDay = 20
    /// Registration attempts per hour, whole service (also invalid ones):
    /// many addresses together cannot keep the WebUntis test fetch busy.
    public var registrationAttemptsPerHour = 60
    public var requestsPerMinutePerIP = 60
    /// Devices whose token became invalid or whose Untis access failed are
    /// deleted after this many days without a successful update.
    public var inactiveRetentionDays = 30
    /// Any device (also an active one) is deleted after this many days
    /// without an authenticated API request (the app asks `GET /v1/changes`
    /// whenever the calendar opens, and at most once a day `GET /v1/device`
    /// at launch or in a background refresh, whichever area is shown): no
    /// Freigabe stays on the server for an app that is gone. 120 days outlast
    /// the summer holidays of an app that is not opened meanwhile. The app
    /// registers again after its next 401.
    public var noContactRetentionDays = 120
    /// WebUntis hosts the server may contact: a Freigabe whose server is not
    /// a subdomain of one of these (`<schule>.webuntis.com`) is refused
    /// before any request (no requests on behalf of others to arbitrary hosts).
    public var allowedUntisHostSuffixes = ["webuntis.com"]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case listenHost, port, dataDirectory, dataKeyFile, apnsKeyFile, apnsKeyID, teamID, allowedBundleIDs, maxDevices,
             consentVersion, windowDays, schedule, curlPath, registrationsPerHourPerIP, registrationsPerDay,
             registrationAttemptsPerHour, requestsPerMinutePerIP, inactiveRetentionDays, noContactRetentionDays, allowedUntisHostSuffixes
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PushConfig()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T { try c.decodeIfPresent(T.self, forKey: key) ?? fallback }
        listenHost = try v(.listenHost, d.listenHost); port = try v(.port, d.port)
        dataDirectory = try v(.dataDirectory, d.dataDirectory); dataKeyFile = try v(.dataKeyFile, d.dataKeyFile)
        apnsKeyFile = try v(.apnsKeyFile, d.apnsKeyFile); apnsKeyID = try v(.apnsKeyID, d.apnsKeyID); teamID = try v(.teamID, d.teamID)
        allowedBundleIDs = try v(.allowedBundleIDs, d.allowedBundleIDs); maxDevices = try v(.maxDevices, d.maxDevices)
        consentVersion = try v(.consentVersion, d.consentVersion); windowDays = try v(.windowDays, d.windowDays)
        schedule = try v(.schedule, d.schedule); curlPath = try v(.curlPath, d.curlPath)
        registrationsPerHourPerIP = try v(.registrationsPerHourPerIP, d.registrationsPerHourPerIP)
        registrationsPerDay = try v(.registrationsPerDay, d.registrationsPerDay)
        registrationAttemptsPerHour = try v(.registrationAttemptsPerHour, d.registrationAttemptsPerHour)
        requestsPerMinutePerIP = try v(.requestsPerMinutePerIP, d.requestsPerMinutePerIP)
        inactiveRetentionDays = try v(.inactiveRetentionDays, d.inactiveRetentionDays)
        noContactRetentionDays = try v(.noContactRetentionDays, d.noContactRetentionDays)
        allowedUntisHostSuffixes = try v(.allowedUntisHostSuffixes, d.allowedUntisHostSuffixes)
    }

    /// Problems that prevent starting (German, for `noty-push check`).
    public var problems: [String] {
        var result: [String] = []
        if !["127.0.0.1", "::1"].contains(listenHost) { result.append("listenHost muss 127.0.0.1 oder ::1 sein (nur über nginx erreichbar).") }
        if !(1024...65535).contains(port) { result.append("port außerhalb 1024–65535.") }
        if !dataDirectory.hasPrefix("/") { result.append("dataDirectory muss absolut sein.") }
        if apnsKeyID.count != 10 || !apnsKeyID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) { result.append("apnsKeyID: 10 Zeichen A–Z/0–9 erwartet.") }
        if teamID.count != 10 || !teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) { result.append("teamID: 10 Zeichen A–Z/0–9 erwartet.") }
        if allowedBundleIDs.isEmpty || !allowedBundleIDs.allSatisfy(Self.isBundleID) { result.append("allowedBundleIDs leer oder ungültig.") }
        if !(1...50).contains(maxDevices) { result.append("maxDevices außerhalb 1–50.") }
        if !(1...28).contains(windowDays) { result.append("windowDays außerhalb 1–28.") }
        if !schedule.isValid { result.append("schedule ungültig (Stunden 0–23, spreadMinutes 1–59).") }
        if !curlPath.hasPrefix("/") { result.append("curlPath muss absolut sein.") }
        if consentVersion.isEmpty || consentVersion.count > 64 { result.append("consentVersion leer oder zu lang.") }
        if registrationsPerHourPerIP < 1 || registrationsPerDay < 1 || registrationAttemptsPerHour < 1 || requestsPerMinutePerIP < 1 {
            result.append("Ratenlimits müssen ≥ 1 sein.")
        }
        if !(1...365).contains(inactiveRetentionDays) { result.append("inactiveRetentionDays außerhalb 1–365.") }
        if !(7...365).contains(noContactRetentionDays) { result.append("noContactRetentionDays außerhalb 7–365.") }
        if allowedUntisHostSuffixes.isEmpty || !allowedUntisHostSuffixes.allSatisfy(Self.isHostSuffix) {
            result.append("allowedUntisHostSuffixes leer oder ungültig (Domains wie „webuntis.com“, ohne Port, keine IP-Adressen).")
        }
        return result
    }

    /// A domain such as „webuntis.com“: lower-case labels of letters, digits
    /// and „-“, at least two labels, the last one not numeric (no IP address).
    static func isHostSuffix(_ text: String) -> Bool {
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        return text.count <= 253 && labels.count >= 2 && labels.allSatisfy(isHostLabel)
            && labels.last.map { $0.contains { $0.isLetter } } == true
    }

    static func isHostLabel(_ label: Substring) -> Bool {
        (1...63).contains(label.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
            && label.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    /// Whether the server may contact the WebUntis host `server` (as
    /// `WebUntisSetup.server` stores it, „host“ or „host:port“): only a
    /// subdomain of an allowed suffix, no port, no IP address literal.
    public func allowsUntisServer(_ server: String) -> Bool {
        let host = server.lowercased()
        guard !host.contains(":"), !host.contains("["), host.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, labels.allSatisfy(Self.isHostLabel),
              labels.last.map({ $0.contains { $0.isLetter } }) == true else { return false }
        return allowedUntisHostSuffixes.contains { suffix in
            let suffix = suffix.lowercased()
            return Self.isHostSuffix(suffix) && host.hasSuffix("." + suffix) && host.count > suffix.count + 1
        }
    }

    static func isBundleID(_ text: String) -> Bool {
        (3...155).contains(text.count) && text.contains(".")
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    public static func load(_ path: String) throws -> PushConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count <= 64_000 else { throw PushError.configuration("Konfiguration zu groß") }
        return try JSONDecoder().decode(PushConfig.self, from: data)
    }

    /// Absolute path of a secret file: as given when absolute, else in
    /// `$CREDENTIALS_DIRECTORY` (systemd LoadCredential), else next to the config.
    public static func secretPath(_ name: String, configPath: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if name.hasPrefix("/") { return name }
        if let directory = environment["CREDENTIALS_DIRECTORY"], !directory.isEmpty { return directory + "/" + name }
        return URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent(name).path
    }
}

public enum PushError: Error, Equatable, CustomStringConvertible {
    case configuration(String)
    case crypto(String)
    case storage(String)
    case transport(String)

    public var description: String {
        switch self {
        case .configuration(let text): "Konfiguration: \(text)"
        case .crypto(let text): "Verschlüsselung: \(text)"
        case .storage(let text): "Speicher: \(text)"
        case .transport(let text): "Verbindung: \(text)"
        }
    }
}
