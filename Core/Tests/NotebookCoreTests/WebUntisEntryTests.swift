import XCTest
@testable import NotebookCore

/// Manual WebUntis entry. Every value here is FICTITIOUS (invented server,
/// school, user and key); no real school data.
final class WebUntisEntryTests: XCTestCase {
    /// RFC 6238 test secret „12345678901234567890“.
    private let rfcKey = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
    private let host = "musterschule.webuntis.example"

    func testCompleteEntryIsTrimmedAndNormalized() throws {
        let check = WebUntis.check(WebUntisEntry(server: "  Musterschule.WebUntis.example \n", school: " muster-gym ",
                                                 user: " max.muster ", key: "gezd gnbv gy3t qojq gezd gnbv gy3t qojq"))
        XCTAssertEqual(check.lines, [])
        XCTAssertFalse(check.swapSuggested)
        let setup = try XCTUnwrap(check.setup)
        XCTAssertEqual(setup.server, host)
        XCTAssertEqual(setup.school, "muster-gym")
        XCTAssertEqual(setup.user, "max.muster")
        XCTAssertEqual(setup.key, rfcKey)
        XCTAssertEqual(check.entry.key, rfcKey)
    }

    func testMissingFieldsAreNamed() {
        XCTAssertEqual(WebUntis.check(WebUntisEntry()).lines, ["Es fehlt: Server, Schule, Benutzer, Schlüssel"])
        let check = WebUntis.check(WebUntisEntry(server: host, school: "muster-gym", user: "max.muster", key: "  "))
        XCTAssertNil(check.setup)
        XCTAssertEqual(check.missing, [.key])
        XCTAssertEqual(check.lines, ["Es fehlt: Schlüssel"])
    }

    func testSwappedServerAndSchoolAreDetectedNotSilentlyUsed() throws {
        // As seen on the iPad: school name in „Server“, server in „Schule“.
        let raw = WebUntisEntry(server: "muster-gym", school: host, user: "max.muster", key: rfcKey)
        let check = WebUntis.check(raw)
        XCTAssertNil(check.setup)
        XCTAssertTrue(check.swapSuggested)
        XCTAssertEqual(check.problems, ["Server und Schule scheinen vertauscht."])
        let fixed = WebUntis.check(check.entry.swapped)
        XCTAssertEqual(fixed.lines, [])
        XCTAssertEqual(try XCTUnwrap(fixed.setup).server, host)
        XCTAssertEqual(fixed.setup?.school, "muster-gym")

        // Server only in the school field.
        let moved = WebUntis.check(WebUntisEntry(server: "", school: host, user: "u", key: rfcKey))
        XCTAssertTrue(moved.swapSuggested)
        XCTAssertEqual(moved.missing, [])
        XCTAssertEqual(WebUntis.check(moved.entry.swapped).lines, ["Es fehlt: Schule"])

        // School name in the server field, school empty: no swap, clear reason.
        let name = WebUntis.check(WebUntisEntry(server: "muster-gym", school: "", user: "u", key: rfcKey))
        XCTAssertFalse(name.swapSuggested)
        XCTAssertEqual(name.missing, [.school])
        XCTAssertEqual(name.problems, ["Server sieht aus wie ein Schulname – erwartet wird eine Adresse wie schulname.webuntis.com."])
    }

    func testBrowserURLsGiveServerAndSchool() throws {
        let check = WebUntis.check(WebUntisEntry(server: "https://\(host)/WebUntis/?school=muster-gym#/basic/login",
                                                 user: "u", key: rfcKey))
        XCTAssertEqual(check.lines, [])
        XCTAssertEqual(check.entry.server, host)
        XCTAssertEqual(check.entry.school, "muster-gym")
        // Typed school wins over the URL.
        XCTAssertEqual(WebUntis.normalizedEntry(WebUntisEntry(server: "https://\(host)/WebUntis/?school=a", school: "b")).school, "b")
        // School in the fragment, percent-encoded.
        XCTAssertEqual(WebUntis.normalizedEntry(WebUntisEntry(server: "\(host)/WebUntis/#/basic/login?school=Muster%20Schule")).school,
                       "Muster Schule")
        // URL pasted into the school field fixes both fields.
        let other = WebUntis.normalizedEntry(WebUntisEntry(server: "muster-gym", school: "https://\(host)/WebUntis/index.do"))
        XCTAssertEqual(other.server, host)
        XCTAssertEqual(other.school, "muster-gym")
        XCTAssertEqual(WebUntis.normalizedEntry(WebUntisEntry(server: "\(host)?school=x")).server, host)
        // Plain http is refused with a reason.
        let http = WebUntis.check(WebUntisEntry(server: "http://\(host)/WebUntis/", school: "s", user: "u", key: rfcKey))
        XCTAssertNil(http.setup)
        XCTAssertEqual(http.problems, ["Server: nur sichere Adressen (https) sind möglich."])
    }

    func testFreigabeLinkPastedIntoAnyFieldFillsAll() throws {
        let link = "untis://setschool?url=\(host)&school=muster-gym&user=max.muster&key=\(rfcKey)&schoolNumber=1234567"
        for field in WebUntisEntryField.allCases {
            var raw = WebUntisEntry(server: "alt", school: "alt", user: "alt", key: "")
            switch field {
            case .server: raw.server = " " + link
            case .school: raw.school = link
            case .user: raw.user = link + "\n"
            case .key: raw.key = link
            }
            let check = WebUntis.check(raw)
            XCTAssertEqual(check.lines, [], field.rawValue)
            XCTAssertEqual(check.setup?.server, host, field.rawValue)
            XCTAssertEqual(check.setup?.school, "muster-gym", field.rawValue)
            XCTAssertEqual(check.setup?.user, "max.muster", field.rawValue)
            XCTAssertEqual(check.setup?.key, rfcKey, field.rawValue)
            XCTAssertEqual(check.setup?.schoolNumber, "1234567", field.rawValue)
        }
        // Clipboard text with surrounding words and a link URL with path.
        let pasted = try XCTUnwrap(WebUntis.parseEntry("Freigabe: UNTIS://setschool?URL=https://\(host)/WebUntis&School=muster-gym&user=anna&key=gezdgnbvgy3tqojq bitte"))
        XCTAssertEqual(pasted, WebUntisEntry(server: host, school: "muster-gym", user: "anna", key: "GEZDGNBVGY3TQOJQ"))
        // Partial link: what is missing is named.
        let partial = WebUntis.check(try XCTUnwrap(WebUntis.parseEntry("untis://setschool?url=\(host)&school=muster-gym&user=anna")))
        XCTAssertEqual(partial.lines, ["Es fehlt: Schlüssel"])
        // Browser URL from the clipboard gives server and school only.
        XCTAssertEqual(WebUntis.parseEntry("https://\(host)/WebUntis/?school=muster-gym#/basic/main"),
                       WebUntisEntry(server: host, school: "muster-gym"))
        XCTAssertNil(WebUntis.parseEntry("irgendein Text"))
        XCTAssertNil(WebUntis.parseEntry(host)) // a bare host is no paste source
        XCTAssertNil(WebUntis.parseEntry("untis://setschool"))
    }

    func testKeyProblemsAreExplainedWithoutTheKey() {
        func problems(_ key: String) -> [String] { WebUntis.check(WebUntisEntry(server: host, school: "s", user: "u", key: key)).problems }
        let wrongCharacters = problems("ABCD0FGH1JKL8NOP")
        XCTAssertEqual(wrongCharacters, ["Schlüssel enthält Zeichen, die darin nicht vorkommen: erlaubt sind nur A–Z und 2–7 (statt 0, 1, 8 meist O, I, B)."])
        XCTAssertEqual(problems("ABCD"), ["Schlüssel ist zu kurz – erwartet wird die lange Buchstaben-Zahlen-Folge aus der Freigabe."])
        XCTAssertEqual(problems(String(repeating: "A", count: 200)), ["Schlüssel ist zu lang."])
        XCTAssertEqual(problems("abcd-efgh ijkl=mnop"), [])
        // No message ever contains the key or a part of it.
        let secretish = "QWERTZUIOPASDFGH"
        for key in [secretish, secretish + "0", String(secretish.prefix(4))] {
            for line in WebUntis.check(WebUntisEntry(server: "x", school: host, user: "u", key: key)).lines {
                XCTAssertFalse(line.contains(String(secretish.prefix(4))), line)
            }
        }
    }

    func testErrorsAreClassifiedInPlainGerman() {
        XCTAssertEqual(WebUntis.problem(.server(code: -8500, message: "invalid schoolname")), .schoolUnknown)
        XCTAssertEqual(WebUntis.problem(.server(code: nil, message: "Unknown school")), .schoolUnknown)
        XCTAssertEqual(WebUntis.problem(.server(code: -8504, message: "bad credentials")), .authentication)
        XCTAssertEqual(WebUntis.problem(.server(code: -8520, message: "not authenticated")), .authentication)
        XCTAssertEqual(WebUntis.problem(.server(code: 0, message: "invalid OTP")), .authentication)
        XCTAssertEqual(WebUntis.problem(.server(code: -7004, message: "no right")),
                       .other("WebUntis meldet einen Fehler (-7004): no right"))
        if case .serverUnreachable = WebUntis.problem(.http(404)) {} else { XCTFail("404") }
        if case .serverUnreachable = WebUntis.problem(.http(503)) {} else { XCTFail("503") }
        XCTAssertEqual(WebUntis.problem(.invalidResponse("Stundenzeit „dddd-dd-dd“")), .unreadable("Stundenzeit „dddd-dd-dd“"))
        XCTAssertTrue(WebUntisProblem.unreadable("Stundenzeit „dddd-dd-dd“").message.contains("dddd-dd-dd"))
        XCTAssertTrue(WebUntisProblem.authentication.message.contains("Uhrzeit"))
    }

    func testWebPageInsteadOfJSONIsNamed() {
        let html = Data("\n  <!DOCTYPE html><html><body>Login</body></html>".utf8)
        XCTAssertThrowsError(try WebUntis.parseUserData(html)) {
            XCTAssertEqual($0 as? WebUntisError, .invalidResponse("Webseite statt Daten – Server-Adresse und Schule prüfen"))
        }
    }
}
