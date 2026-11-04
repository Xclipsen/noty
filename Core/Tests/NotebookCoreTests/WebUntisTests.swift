import XCTest
@testable import NotebookCore

/// Kalender Stufe B1. Every fixture here is FICTITIOUS (invented server,
/// school, user, key, subjects and rooms); no real timetable data.
final class WebUntisTests: XCTestCase {
    private let berlin = TimeZone(identifier: "Europe/Berlin")!
    private let connection = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    /// RFC 6238 test secret „12345678901234567890“.
    private let rfcKey = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    private func day(_ text: String) -> CivilDate { CivilDate(text)! }
    private func berlinDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = berlin
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: Setup / QR

    func testParsesFreigabeQRCodeTolerantly() throws {
        let setup = try WebUntis.parseSetup("untis://setschool?url=demo.webuntis.example&school=Demo%20Schule&user=max.muster&key=\(rfcKey)&schoolNumber=1234567")
        XCTAssertEqual(setup.server, "demo.webuntis.example")
        XCTAssertEqual(setup.school, "Demo Schule")
        XCTAssertEqual(setup.user, "max.muster")
        XCTAssertEqual(setup.key, rfcKey)
        XCTAssertEqual(setup.schoolNumber, "1234567")
        XCTAssertEqual(setup.secret, Data("12345678901234567890".utf8))

        // Other order, upper-case names, https URL with path, key in groups, no school number.
        let other = try WebUntis.parseSetup("  UNTIS://setschool?KEY=gezd gnbv gy3t qojq gezd gnbv gy3t qojq&User=anna&School=demo-bk&URL=https://Demo.WebUntis.example/WebUntis/?school=x&extra=1 ")
        XCTAssertEqual(other.server, "demo.webuntis.example")
        XCTAssertEqual(other.school, "demo-bk")
        XCTAssertEqual(other.user, "anna")
        XCTAssertEqual(other.key, rfcKey)
        XCTAssertNil(other.schoolNumber)
    }

    func testRejectsInvalidSetups() {
        let bad = [
            "https://demo.webuntis.example/?school=x",                                   // not a Freigabe code
            "untis://setschool?url=demo.webuntis.example&school=s&user=u",                // key missing
            "untis://setschool?url=demo.webuntis.example&school=s&user=u&key=1189!",     // not base32
            "untis://setschool?url=http://demo.webuntis.example&school=s&user=u&key=\(rfcKey)", // http
            "untis://setschool?url=localhost&school=s&user=u&key=\(rfcKey)",              // no domain
            "untis://setschool?url=demo.webuntis.example&school=&user=u&key=\(rfcKey)",   // empty school
        ]
        for text in bad { XCTAssertThrowsError(try WebUntis.parseSetup(text), text) }
        XCTAssertEqual(WebUntis.normalizedServer("demo.webuntis.example:8443"), "demo.webuntis.example:8443")
        XCTAssertNil(WebUntis.normalizedServer("demo.webuntis.example:99999"))
        XCTAssertNil(WebUntis.normalizedServer("demo..example"))
    }

    // MARK: TOTP

    func testTOTPMatchesRFC6238Vectors() {
        let secret = TOTP.base32Decode(rfcKey)!
        let vectors: [(Double, String)] = [(59, "287082"), (1_111_111_109, "081804"), (1_111_111_111, "050471"),
                                           (1_234_567_890, "005924"), (2_000_000_000, "279037"), (20_000_000_000, "353130")]
        for (time, code) in vectors {
            XCTAssertEqual(TOTP.code(secret: secret, at: Date(timeIntervalSince1970: time), hmacSHA1: TestSHA1.hmac), code, "T=\(time)")
        }
        XCTAssertEqual(TOTP.code(secret: secret, at: Date(timeIntervalSince1970: 59), digits: 8, hmacSHA1: TestSHA1.hmac), "94287082")
        XCTAssertNil(TOTP.base32Decode("01"))
    }

    // MARK: Requests

    func testRequestBodiesCarryAuthAndInclusiveEndDate() throws {
        let setup = try WebUntisSetup(server: "demo.webuntis.example", school: "demo+schule", user: "max.muster", key: rfcKey)
        let url = try XCTUnwrap(WebUntis.endpoint(setup, method: "getTimetable2017"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "demo.webuntis.example")
        XCTAssertEqual(url.path, "/WebUntis/jsonrpc_intern.do")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "m" }?.value, "getTimetable2017")
        XCTAssertEqual(items.first { $0.name == "school" }?.value, "demo+schule")
        XCTAssertEqual(items.first { $0.name == "v" }?.value, "i2.2")

        let time = Date(timeIntervalSince1970: 1_111_111_111.25)
        let user = WebUntisUser(elementType: "STUDENT", elementID: 4711)
        let body = try WebUntis.timetableBody(setup, user: user, start: day("2026-11-02"), end: day("2026-11-09"),
                                              at: time, requestID: "r1", hmacSHA1: TestSHA1.hmac)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(json["method"] as? String, "getTimetable2017")
        let params = try XCTUnwrap((json["params"] as? [[String: Any]])?.first)
        XCTAssertEqual(params["id"] as? Int, 4711)
        XCTAssertEqual(params["type"] as? String, "STUDENT")
        XCTAssertEqual(params["startDate"] as? String, "2026-11-02")
        XCTAssertEqual(params["endDate"] as? String, "2026-11-08") // inclusive last day
        let auth = try XCTUnwrap(params["auth"] as? [String: Any])
        XCTAssertEqual(auth["user"] as? String, "max.muster")
        XCTAssertEqual(auth["otp"] as? Int, 50471)
        XCTAssertEqual((auth["clientTime"] as? NSNumber)?.int64Value, 1_111_111_111_250)

        let userBody = try JSONSerialization.jsonObject(with: WebUntis.userDataBody(setup, at: time, hmacSHA1: TestSHA1.hmac)) as? [String: Any]
        XCTAssertEqual(userBody?["method"] as? String, "getUserData2017")
        let userParams = (userBody?["params"] as? [[String: Any]])?.first
        XCTAssertEqual(userParams?["elementId"] as? Int, 0)
        XCTAssertEqual(userParams?["deviceOs"] as? String, "AND")
    }

    // MARK: Responses

    static let userDataFixture = """
    {"jsonrpc":"2.0","id":"r0","result":{
      "userData":{"elemType":"STUDENT","elemId":4711,"displayName":"Muster Max","rights":["R_MY_TIMETABLE"]},
      "masterData":{
        "subjects":[{"id":1,"name":"M","longName":"Mathematik","foreColor":"000000","backColor":"ff0000","active":true},
                    {"id":2,"name":"D","longName":"Deutsch","active":true},
                    {"id":3,"name":"RW","longName":"","active":true}],
        "rooms":[{"id":10,"name":"R101","longName":"Raum 101"},{"id":11,"name":"R202"}],
        "klassen":[{"id":20,"name":"DEMO1"}],
        "teachers":[],
        "holidays":[{"id":7,"name":"HF","longName":"Herbstferien Demo","startDate":"2026-10-12","endDate":"2026-10-24"},
                    {"id":8,"name":"Tag","longName":"","startDate":"2026-11-11","endDate":"2026-11-11"}],
        "schoolyears":[]
      }}}
    """

    func testParsesUserDataAndHolidaysWithExclusiveEnd() throws {
        let user = try WebUntis.parseUserData(Data(Self.userDataFixture.utf8))
        XCTAssertEqual(user.elementType, "STUDENT")
        XCTAssertEqual(user.elementID, 4711)
        XCTAssertEqual(user.subjects[1]?.longName, "Mathematik")
        XCTAssertNil(user.subjects[3]?.longName) // blank long name → short name is used
        XCTAssertEqual(user.rooms[11], "R202")
        XCTAssertTrue(user.teachers.isEmpty)
        XCTAssertEqual(user.holidays.map(\.name), ["Herbstferien Demo", "Tag"])
        XCTAssertEqual(user.holidays[0].start, day("2026-10-12"))
        XCTAssertEqual(user.holidays[0].end, day("2026-10-25"))
        XCTAssertEqual(user.holidays[1].end, day("2026-11-12"))
    }

    private func period(_ id: Int, _ start: String, _ end: String, subject: Int = 1, room: Int = 10, orgRoom: Int? = nil,
                        states: String = "[\"REGULAR\"]", extra: String = "") -> String {
        let org = orgRoom.map { ",\"orgId\":\($0)" } ?? ",\"orgId\":\(room)"
        return """
        {"id":\(id),"lessonId":900\(subject),"startDateTime":"\(start)","endDateTime":"\(end)",
         "elements":[{"type":"CLASS","id":20,"orgId":20},{"type":"SUBJECT","id":\(subject),"orgId":\(subject)},{"type":"ROOM","id":\(room)\(org)}],
         "is":\(states),"text":{"lesson":"","substitution":"","info":""},"homeWorks":[],"exam":null,"can":[]\(extra)}
        """
    }

    private func timetable(_ periods: [String]) -> Data {
        Data("{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"result\":{\"timetable\":{\"displayableStartDate\":\"2026-11-02\",\"displayableEndDate\":\"2026-11-08\",\"periods\":[\(periods.joined(separator: ","))]}}}".utf8)
    }

    private func user() throws -> WebUntisUser { try WebUntis.parseUserData(Data(Self.userDataFixture.utf8)) }

    func testNormalizesLessonsAndStatusesBestEffort() throws {
        let data = timetable([
            period(101, "2026-11-02T08:00", "2026-11-02T09:30"),
            period(102, "2026-11-02T09:45", "2026-11-02T11:15", subject: 2, states: "[\"CANCELLED\"]"),
            period(103, "2026-11-03T08:00", "2026-11-03T09:30", room: 11, orgRoom: 10),
            period(104, "2026-11-03T09:45", "2026-11-03T11:15", extra: ",\"exam\":{\"id\":5,\"name\":\"Klausur\"}"),
            period(105, "2026-11-04T08:00", "2026-11-04T09:30", subject: 3, states: "[\"ZUKUNFT_X\"]"),
            period(106, "2026-11-12T08:00", "2026-11-12T09:30"), // outside the requested week
        ].map { $0.replacingOccurrences(of: "\"exam\":null,\"can\":[],\"exam\"", with: "\"can\":[],\"exam\"") })
        let lessons = try WebUntis.parseTimetable(data, user: user(), connection: connection, timeZone: berlin,
                                                  start: day("2026-11-02"), end: day("2026-11-09"))
        XCTAssertEqual(lessons.map(\.key.sourceID), ["101", "102", "103", "104", "105"])
        let regular = lessons[0]
        XCTAssertEqual(regular.title, "Mathematik")
        XCTAssertEqual(regular.rooms, ["R101"])
        XCTAssertEqual(regular.classes, ["DEMO1"])
        XCTAssertEqual(regular.statuses, [])
        XCTAssertEqual(regular.rawStates, ["REGULAR"])
        XCTAssertEqual(regular.key.seriesID, "9001")
        XCTAssertEqual(regular.key.originalStart, "2026-11-02T08:00")
        XCTAssertEqual(regular.start, berlinDate(2026, 11, 2, 8, 0))
        XCTAssertEqual(regular.date, day("2026-11-02"))
        XCTAssertTrue(regular.teachers.isEmpty) // not delivered for this fictitious student
        XCTAssertTrue(lessons[1].isCancelled)
        XCTAssertEqual(lessons[2].statuses, [.roomChanged])
        XCTAssertEqual(lessons[2].rooms, ["R202"])
        XCTAssertEqual(lessons[2].originalRooms, ["R101"])
        XCTAssertEqual(lessons[3].statuses, [.exam])
        XCTAssertEqual(lessons[4].statuses, [.other("ZUKUNFT_X")])
        XCTAssertEqual(lessons[4].title, "RW")
        // Identity: same answer → same ids (re-reading creates no duplicates).
        let again = try WebUntis.parseTimetable(data, user: user(), connection: connection, timeZone: berlin,
                                                start: day("2026-11-02"), end: day("2026-11-09"))
        XCTAssertEqual(again.map(\.id), lessons.map(\.id))
    }

    func testDaylightSavingTransitionsUseLocalSchoolTime() throws {
        // 29.03.2026 (spring forward) and 25.10.2026 (fall back) are Sundays; the Mondays after as well.
        let data = timetable([
            period(201, "2026-03-27T08:00", "2026-03-27T09:30"),
            period(202, "2026-03-30T08:00", "2026-03-30T09:30"),
            period(203, "2026-10-26T08:00", "2026-10-26T09:30"),
        ])
        let spring = try WebUntis.parseTimetable(data, user: user(), connection: connection, timeZone: berlin,
                                                 start: day("2026-03-23"), end: day("2026-04-01"))
        XCTAssertEqual(spring.count, 2)
        XCTAssertEqual(spring[0].start.timeIntervalSince1970, 1_774_594_800) // 07:00 UTC (CET)
        XCTAssertEqual(spring[1].start.timeIntervalSince1970, 1_774_850_400) // 06:00 UTC (CEST)
        XCTAssertEqual(spring[1].end.timeIntervalSince(spring[1].start), 90 * 60)
        let autumn = try WebUntis.parseTimetable(data, user: user(), connection: connection, timeZone: berlin,
                                                 start: day("2026-10-26"), end: day("2026-10-27"))
        XCTAssertEqual(autumn.map(\.key.sourceID), ["203"])
        XCTAssertEqual(autumn[0].start, berlinDate(2026, 10, 26, 8, 0))
        XCTAssertEqual(autumn[0].start.timeIntervalSince1970, 1_792_998_000) // 07:00 UTC (CET again)
    }

    /// First device run (04.11.2026): the strict „YYYY-MM-DDTHH:MM“ parser
    /// rejected the real answer („Stundenzeit“). Every tolerated form is the
    /// same local wall-clock time.
    func testLessonTimesAreReadTolerantlyAsLocalTime() throws {
        let forms = ["2026-11-04T07:45Z", "2026-11-04T07:45", "2026-11-04T07:45:00", "2026-11-04T07:45:00.000Z",
                     "2026-11-04 07:45", "2026-11-04T7:45Z"]
        for form in forms {
            let parsed = try XCTUnwrap(WebUntis.localDateTime(form), form)
            XCTAssertEqual(parsed.date, day("2026-11-04"), form)
            XCTAssertEqual(parsed.components.hour, 7, form)
            XCTAssertEqual(parsed.components.minute, 45, form)
            XCTAssertEqual(parsed.text, "2026-11-04T07:45", form) // identity independent of the form
        }
        for bad in ["2026-11-04T07:45+01:00", "2026-11-04", "2026-11-04T24:00Z", "2026-11-04T07:5Z", "04.11.2026 07:45", "2026-11-04T07:45:7"] {
            XCTAssertNil(WebUntis.localDateTime(bad), bad)
        }
        let data = timetable([period(301, "2026-11-04T07:45Z", "2026-11-04T09:15Z"),
                              period(302, "2026-11-04T09:30Z", "2026-11-04T09:30Z"),   // zero length (e.g. a note)
                              period(303, "2026-11-05T08:00Z", "2026-11-06T13:00Z")])  // event over two days
        let lessons = try WebUntis.parseTimetable(data, user: user(), connection: connection, timeZone: berlin,
                                                  start: day("2026-11-02"), end: day("2026-11-09"))
        XCTAssertEqual(lessons.map(\.key.sourceID), ["301", "302", "303"])
        XCTAssertEqual(lessons[0].start, berlinDate(2026, 11, 4, 7, 45)) // local, not UTC
        XCTAssertEqual(lessons[0].end, berlinDate(2026, 11, 4, 9, 15))
        // The error names the shape only, never the value.
        XCTAssertThrowsError(try WebUntis.parseTimetable(timetable([period(304, "2026-11-04T07:45+01:00", "2026-11-04T09:15Z")]),
                                                         user: user(), connection: connection, timeZone: berlin,
                                                         start: day("2026-11-02"), end: day("2026-11-09"))) {
            XCTAssertEqual($0 as? WebUntisError, .invalidResponse("Stundenzeit „dddd-dd-ddTdd:dd+dd:dd“"))
        }
    }

    func testPartialOrInvalidAnswersAreRejectedNotEmpty() throws {
        let start = day("2026-11-02"), end = day("2026-11-09")
        func parse(_ data: Data) throws -> [CalendarLesson] {
            try WebUntis.parseTimetable(data, user: user(), connection: connection, timeZone: berlin, start: start, end: end)
        }
        let full = timetable([period(101, "2026-11-02T08:00", "2026-11-02T09:30"), period(102, "2026-11-02T09:45", "2026-11-02T11:15")])
        // Truncated transfer.
        XCTAssertThrowsError(try parse(full.prefix(full.count - 40))) { XCTAssertEqual($0 as? WebUntisError, .invalidResponse("Format")) }
        // Result without a period list is not „no lessons“.
        XCTAssertThrowsError(try parse(Data(#"{"jsonrpc":"2.0","id":"r","result":{"timetable":{}}}"#.utf8)))
        XCTAssertThrowsError(try parse(Data(#"{"jsonrpc":"2.0","id":"r","result":null}"#.utf8)))
        XCTAssertThrowsError(try parse(Data(#"{"jsonrpc":"2.0","id":"r","result":{}}"#.utf8)))
        // Server error.
        XCTAssertThrowsError(try parse(Data(#"{"jsonrpc":"2.0","id":"r","error":{"code":-8520,"message":"not authenticated"}}"#.utf8))) {
            XCTAssertEqual($0 as? WebUntisError, .server(code: -8520, message: "not authenticated"))
        }
        // One broken period rejects everything.
        XCTAssertThrowsError(try parse(timetable([period(101, "2026-11-02T08:00", "2026-11-02T09:30"),
                                                  period(102, "2026-11-02T09:45", "2026-11-02T09:00")])))
        XCTAssertThrowsError(try parse(timetable([period(101, "2026-11-02T08h00", "2026-11-02T09:30")])))
        XCTAssertThrowsError(try parse(timetable([period(101, "2026-11-02T08:00", "2026-11-02T09:30"),
                                                  period(101, "2026-11-02T08:00", "2026-11-02T09:30")])))
        // A really empty week is a valid, empty answer.
        XCTAssertEqual(try parse(timetable([])), [])
        XCTAssertThrowsError(try WebUntis.parseUserData(Data(#"{"jsonrpc":"2.0","id":"r","result":{"userData":{"elemType":"STUDENT","elemId":0},"masterData":{}}}"#.utf8)))
    }

    // MARK: Snapshot merge

    private func fetch(_ start: String, _ end: String, at time: Double, _ lessons: [CalendarLesson], connection: UUID? = nil) -> CalendarTimetableFetch {
        CalendarTimetableFetch(connection: connection ?? self.connection, start: day(start), end: day(end),
                               fetchedAt: Date(timeIntervalSince1970: time), lessons: lessons)
    }

    private func lesson(_ id: String, _ date: String, connection: UUID? = nil) -> CalendarLesson {
        let d = day(date)
        let start = d.start(in: { var c = Calendar(identifier: .gregorian); c.timeZone = berlin; return c }()).addingTimeInterval(8 * 3600)
        return CalendarLesson(key: CalendarOccurrenceKey(provider: "webuntis", connection: connection ?? self.connection, sourceID: id,
                                                         seriesID: nil, originalStart: "\(date)T08:00"),
                              date: d, start: start, end: start.addingTimeInterval(5400))
    }

    func testSnapshotCoverageDistinguishesNotLoadedFromNoLessons() throws {
        var snapshot = CalendarSourceSnapshot(connection: connection)
        XCTAssertEqual(snapshot.coverage(from: day("2026-11-02"), to: day("2026-11-09")), .notLoaded)
        XCTAssertNil(snapshot.lessons(on: day("2026-11-03")))
        try snapshot.merge(fetch("2026-11-02", "2026-11-05", at: 1000, [lesson("1", "2026-11-02"), lesson("9", "2026-11-20")]))
        XCTAssertEqual(snapshot.lessons(on: day("2026-11-02"))?.map(\.key.sourceID), ["1"])
        XCTAssertEqual(snapshot.lessons(on: day("2026-11-03")), []) // loaded, no lessons
        XCTAssertNil(snapshot.lessons(on: day("2026-11-20")))       // outside the request: not stored
        XCTAssertEqual(snapshot.coverage(from: day("2026-11-02"), to: day("2026-11-09")), .partial(oldest: Date(timeIntervalSince1970: 1000)))
        XCTAssertEqual(snapshot.coverage(from: day("2026-11-02"), to: day("2026-11-05")), .loaded(oldest: Date(timeIntervalSince1970: 1000)))
    }

    func testOlderFetchNeverReplacesNewerDaysAndOtherConnectionIsRejected() throws {
        var snapshot = CalendarSourceSnapshot(connection: connection)
        try snapshot.merge(fetch("2026-11-02", "2026-11-04", at: 2000, [lesson("new", "2026-11-02")]))
        // An answer that was requested earlier arrives late: only its untouched day counts.
        let taken = try snapshot.merge(fetch("2026-11-02", "2026-11-05", at: 1000, [lesson("old", "2026-11-02"), lesson("old4", "2026-11-04")]))
        XCTAssertEqual(taken, 1)
        XCTAssertEqual(snapshot.lessons(on: day("2026-11-02"))?.map(\.key.sourceID), ["new"])
        XCTAssertEqual(snapshot.lessons(on: day("2026-11-04"))?.map(\.key.sourceID), ["old4"])
        // A newer fetch replaces the day completely (lesson removed at the source).
        try snapshot.merge(fetch("2026-11-02", "2026-11-03", at: 3000, []))
        XCTAssertEqual(snapshot.lessons(on: day("2026-11-02")), [])
        XCTAssertThrowsError(try snapshot.merge(fetch("2026-11-02", "2026-11-03", at: 4000, [], connection: UUID())))
        XCTAssertThrowsError(try snapshot.merge(fetch("2026-11-02", "2026-11-02", at: 4000, [])))
        try snapshot.validate()
        // Holidays: an older list never replaces a newer one.
        snapshot.replaceHolidays([CalendarHoliday(id: "1", name: "A", start: day("2026-12-21"), end: day("2027-01-02"))], fetchedAt: Date(timeIntervalSince1970: 50))
        snapshot.replaceHolidays([], fetchedAt: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(snapshot.holidays.map(\.name), ["A"])
    }

    func testSnapshotIsBounded() throws {
        var snapshot = CalendarSourceSnapshot(connection: connection)
        var start = day("2024-01-01")
        for index in 0..<25 {
            try snapshot.merge(fetch(start.description, start.adding(days: 60).description, at: Double(index), [lesson("\(index)", start.description)]))
            start = start.adding(days: 60)
        }
        XCTAssertLessThanOrEqual(snapshot.days.count, CalendarSourceSnapshot.maximumDays)
        // The days around the newest request stay.
        XCTAssertNotNil(snapshot.lessons(on: start.adding(days: -60)))
        try snapshot.validate()
    }
}

/// Minimal SHA-1/HMAC for the RFC vectors (the app uses CryptoKit).
enum TestSHA1 {
    static func hash(_ data: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var message = data
        let length = UInt64(data.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8((length >> UInt64(shift)) & 0xFF)) }
        for chunk in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let j = chunk + 4 * i
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<80 { let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]; w[i] = (x << 1) | (x >> 31) }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let t = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = t
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        return h.flatMap { value in (0..<4).map { UInt8((value >> UInt32(24 - 8 * $0)) & 0xFF) } }
    }

    static func hmac(_ key: Data, _ message: Data) -> Data {
        var block = [UInt8](key.count > 64 ? Data(hash([UInt8](key))) : key)
        block += [UInt8](repeating: 0, count: 64 - block.count)
        let inner = hash(block.map { $0 ^ 0x36 } + [UInt8](message))
        return Data(hash(block.map { $0 ^ 0x5C } + inner))
    }
}
