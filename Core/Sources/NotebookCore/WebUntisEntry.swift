import Foundation

// Kalender: manual entry of a Untis Mobile „Freigabe“ (server, school, user,
// key). Device run with Build 103/104 showed swapped server/school fields and
// a missing key with silently grey buttons. These pure functions normalize
// tolerant input (full browser URLs, pasted `untis://setschool?…` links,
// grouped keys) and name what is still missing or invalid. Messages never
// contain the key or any of its characters.

/// Raw, possibly incomplete values of the manual form.
public struct WebUntisEntry: Equatable, Sendable {
    public var server: String
    public var school: String
    public var user: String
    public var key: String
    public var schoolNumber: String?

    public init(server: String = "", school: String = "", user: String = "", key: String = "", schoolNumber: String? = nil) {
        self.server = server; self.school = school; self.user = user; self.key = key; self.schoolNumber = schoolNumber
    }

    /// Server and school exchanged (the „Vertauscht? Tauschen“ action).
    public var swapped: WebUntisEntry {
        var copy = self
        (copy.server, copy.school) = (school, server)
        return copy
    }
}

public enum WebUntisEntryField: String, CaseIterable, Sendable {
    case server = "Server", school = "Schule", user = "Benutzer", key = "Schlüssel"
}

/// Result of checking the form: the normalized values, the usable setup (nil
/// while anything is missing or invalid) and visible reasons.
public struct WebUntisEntryCheck: Equatable, Sendable {
    public var entry: WebUntisEntry
    public var setup: WebUntisSetup?
    public var missing: [WebUntisEntryField]
    /// Plain German reasons besides missing fields, in field order.
    public var problems: [String]
    /// Server and school look exchanged; offer „Vertauscht? Tauschen“.
    public var swapSuggested: Bool

    /// Lines for the status text below the buttons (empty when usable).
    public var lines: [String] {
        (missing.isEmpty ? [] : ["Es fehlt: " + missing.map(\.rawValue).joined(separator: ", ")]) + problems
    }
}

/// Plain-German category of a failed „Verbindung testen“.
public enum WebUntisProblem: Equatable, Sendable {
    case serverUnreachable(String)
    case schoolUnknown
    case authentication
    case unreadable(String)
    case other(String)

    public var message: String {
        switch self {
        case .serverUnreachable(let detail):
            "Server nicht erreichbar: \(detail) Bitte die Server-Adresse prüfen (z. B. schulname.webuntis.com)."
        case .schoolUnknown:
            "Der Server kennt diese Schule nicht. Bitte den Schul-Anmeldenamen prüfen (steht in der Freigabe bzw. in der WebUntis-Adresse hinter „school=“)."
        case .authentication:
            "Benutzer oder Schlüssel stimmen nicht. Bitte die Freigabe neu scannen oder beide Angaben prüfen. Auch eine falsche Uhrzeit des iPads verhindert die Anmeldung (Einstellungen → Allgemein → Datum & Uhrzeit → Automatisch)."
        case .unreadable(let reason):
            "Die Antwort von WebUntis ist nicht lesbar (\(reason)). Der bisherige Stand bleibt erhalten."
        case .other(let text): text
        }
    }
}

extension WebUntis {
    static let base32Alphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    public static let keyLengthRange = 8...128

    // MARK: Paste and URLs

    /// Values of a pasted `untis://setschool?…` link (anywhere in the text)
    /// or of a WebUntis browser URL (`https://host/WebUntis/?school=…#/…`,
    /// server and, if present, school). Nil for anything else. Partial values
    /// are returned as found; `check` names what is missing.
    public static func parseEntry(_ text: String) -> WebUntisEntry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = untisLink(in: trimmed) {
            guard let components = URLComponents(string: link) else { return nil }
            var values: [String: String] = [:]
            for item in components.queryItems ?? [] {
                let name = item.name.lowercased()
                if values[name] == nil, let value = item.value { values[name] = value }
            }
            var entry = WebUntisEntry()
            if let server = values["url"] ?? values["server"] {
                let web = webURL(server)
                entry.server = web?.server ?? server.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            entry.school = values["school"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            entry.user = values["user"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            entry.key = normalizedKey(values["key"] ?? "")
            entry.schoolNumber = values["schoolnumber"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            guard !(entry.server.isEmpty && entry.school.isEmpty && entry.user.isEmpty && entry.key.isEmpty) else { return nil }
            return entry
        }
        if let web = webURL(trimmed) { return WebUntisEntry(server: web.server, school: web.school ?? "") }
        return nil
    }

    /// `untis://…` up to the next whitespace, case-insensitive scheme.
    static func untisLink(in text: String) -> String? {
        guard let range = text.range(of: "untis://", options: .caseInsensitive) else { return nil }
        let tail = text[range.lowerBound...]
        return String(tail.prefix { !$0.isWhitespace })
    }

    /// Host and `school=` of something URL-shaped („https://…“, or
    /// „host/path…“). Plain hosts without a path are not URLs here.
    static func webURL(_ raw: String) -> (server: String, school: String?)? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasScheme = text.contains("://")
        guard hasScheme || text.contains("/") || text.contains("?") || text.contains("#") else { return nil }
        guard let server = normalizedServer(text) else { return nil }
        return (server, schoolParameter(text))
    }

    /// `school=` value from query or fragment (WebUntis puts it in either),
    /// percent-decoded; nil when absent or empty.
    static func schoolParameter(_ text: String) -> String? {
        var search = text[...]
        while let range = search.range(of: "school=", options: .caseInsensitive) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            if before == nil || before == "?" || before == "&" || before == "#" || before == "/" {
                let value = search[range.upperBound...].prefix { $0 != "&" && $0 != "#" && !$0.isWhitespace }
                let decoded = String(value).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(value)
                return decoded.trimmingCharacters(in: .whitespaces).nilIfBlank
            }
            search = search[range.upperBound...]
        }
        return nil
    }

    // MARK: Normalize and check

    /// Trimmed, links/URLs resolved, key without spaces in upper case, valid
    /// hosts in lower case. Server/school are NOT exchanged automatically
    /// (`check` suggests it).
    public static func normalizedEntry(_ raw: WebUntisEntry) -> WebUntisEntry {
        var entry = WebUntisEntry(server: raw.server.trimmingCharacters(in: .whitespacesAndNewlines),
                                  school: raw.school.trimmingCharacters(in: .whitespacesAndNewlines),
                                  user: raw.user.trimmingCharacters(in: .whitespacesAndNewlines),
                                  key: raw.key, schoolNumber: raw.schoolNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank)
        // A whole Freigabe link pasted into any field fills every field it names.
        for value in [raw.server, raw.school, raw.user, raw.key] where untisLink(in: value) != nil {
            if let link = parseEntry(value) {
                // Fields are only kept from the form where the link has no value;
                // the field holding the link itself is cleared first.
                if raw.server == value { entry.server = "" }
                if raw.school == value { entry.school = "" }
                if raw.user == value { entry.user = "" }
                if raw.key == value { entry.key = "" }
                if !link.server.isEmpty { entry.server = link.server }
                if !link.school.isEmpty { entry.school = link.school }
                if !link.user.isEmpty { entry.user = link.user }
                if !link.key.isEmpty { entry.key = link.key }
                if let number = link.schoolNumber { entry.schoolNumber = number }
            }
            break
        }
        // Browser URL in the server field.
        if let web = webURL(entry.server) {
            entry.server = web.server
            if let school = web.school, entry.school.isEmpty || looksLikeHost(entry.school) { entry.school = school }
        }
        // Browser URL in the school field: it names the server (and school).
        if let web = webURL(entry.school) {
            let previous = entry.server
            entry.server = web.server
            entry.school = web.school ?? (looksLikeSchoolName(previous) ? previous : "")
        }
        if let host = normalizedServer(entry.server) { entry.server = host }
        entry.key = normalizedKey(entry.key)
        return entry
    }

    /// Something like „name.webuntis.com“ (a dot, no spaces, valid host).
    static func looksLikeHost(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.contains(" ") && text.contains(".") && normalizedServer(text) != nil
    }

    /// A non-empty value without a dot (school login names have none here).
    static func looksLikeSchoolName(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && !text.contains(".") && !text.contains("/")
    }

    public static func check(_ raw: WebUntisEntry) -> WebUntisEntryCheck {
        let entry = normalizedEntry(raw)
        var missing: [WebUntisEntryField] = []
        var problems: [String] = []
        var swap = false

        let schoolIsHost = looksLikeHost(entry.school)
        if entry.server.isEmpty {
            if schoolIsHost {
                problems.append("Schule sieht aus wie eine Server-Adresse – gehört ins Feld „Server“.")
                swap = true
            } else { missing.append(.server) }
        } else if normalizedServer(entry.server) == nil {
            if schoolIsHost && looksLikeSchoolName(entry.server) {
                problems.append("Server und Schule scheinen vertauscht.")
                swap = true
            } else if looksLikeSchoolName(entry.server) {
                problems.append("Server sieht aus wie ein Schulname – erwartet wird eine Adresse wie schulname.webuntis.com.")
            } else if entry.server.lowercased().hasPrefix("http://") {
                problems.append("Server: nur sichere Adressen (https) sind möglich.")
            } else {
                problems.append("Server ist keine gültige Adresse (z. B. schulname.webuntis.com).")
            }
        }

        if entry.school.isEmpty {
            if !entry.server.isEmpty || !schoolIsHost { missing.append(.school) }
        } else if schoolIsHost && !swap {
            problems.append("Schule sieht aus wie eine Server-Adresse – erwartet wird der Schul-Anmeldename ohne Punkt.")
        } else if entry.school.count > 200 || entry.school.contains(where: { $0.isNewline }) {
            problems.append("Schule ist zu lang oder enthält Zeilenumbrüche.")
        }

        if entry.user.isEmpty { missing.append(.user) }
        else if entry.user.count > 200 || entry.user.contains(where: { $0.isNewline }) {
            problems.append("Benutzer ist zu lang oder enthält Zeilenumbrüche.")
        }

        if entry.key.isEmpty { missing.append(.key) }
        else if let problem = keyProblem(entry.key) { problems.append(problem) }

        var setup: WebUntisSetup?
        if missing.isEmpty && problems.isEmpty {
            setup = try? WebUntisSetup(server: entry.server, school: entry.school, user: entry.user, key: entry.key,
                                       schoolNumber: entry.schoolNumber)
            if setup == nil { problems.append("Die Angaben sind noch nicht vollständig gültig.") }
        }
        return WebUntisEntryCheck(entry: entry, setup: setup, missing: missing, problems: problems, swapSuggested: swap)
    }

    /// Reason why a normalized key is unusable, without naming its characters.
    static func keyProblem(_ key: String) -> String? {
        if !key.allSatisfy({ base32Alphabet.contains($0) }) {
            return "Schlüssel enthält Zeichen, die darin nicht vorkommen: erlaubt sind nur A–Z und 2–7 (statt 0, 1, 8 meist O, I, B)."
        }
        if key.count < keyLengthRange.lowerBound {
            return "Schlüssel ist zu kurz – erwartet wird die lange Buchstaben-Zahlen-Folge aus der Freigabe."
        }
        if key.count > keyLengthRange.upperBound { return "Schlüssel ist zu lang." }
        guard let secret = TOTP.base32Decode(key), secret.count >= 5 else { return "Schlüssel ist ungültig." }
        return nil
    }

    // MARK: Errors

    /// Category of a WebUntis error. JSON-RPC codes besides -8520 are taken
    /// from community documentation (UNVERIFIED); message words are a fallback.
    public static func problem(_ error: WebUntisError) -> WebUntisProblem {
        switch error {
        case .http(let status):
            if status == 404 { return .serverUnreachable("Unter dieser Adresse antwortet kein WebUntis (HTTP 404).") }
            if (300..<400).contains(status) { return .serverUnreachable("Der Server leitet um (HTTP \(status)).") }
            return .serverUnreachable("WebUntis antwortet mit einem Fehler (HTTP \(status)).")
        case .server(let code, let message):
            let text = message.lowercased()
            if code == -8500 || (text.contains("school") && !text.contains("year")) || text.contains("schule") || text.contains("mandant") {
                return .schoolUnknown
            }
            if [-8504, -8502, -8520, -8998].contains(code ?? 0)
                || ["auth", "otp", "password", "passwort", "credential", "user", "benutzer", "secret", "login"].contains(where: text.contains) {
                return .authentication
            }
            return .other(code.map { "WebUntis meldet einen Fehler (\($0)): \(message)" } ?? "WebUntis meldet einen Fehler: \(message)")
        case .invalidResponse(let reason): return .unreadable(reason)
        case .tooLarge: return .unreadable("zu groß")
        case .invalidSetup: return .other(error.localizedDescription)
        }
    }
}
