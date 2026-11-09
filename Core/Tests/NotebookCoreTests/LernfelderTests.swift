import XCTest
@testable import NotebookCore

/// Lernfelder (docs/LERNFELDER.md): material packages (catalogue, search,
/// stored-ZIP reader, install), calendar format 5 (study fields, rules,
/// lesson topics) with migration and archive, and the lesson sections of a
/// Lernfeld notebook. Fictitious data only: no real script, platform id or
/// timetable.
final class LernfelderTests: XCTestCase {
    private var root: URL!
    private let zone = TimeZone(identifier: "Europe/Berlin")!
    private var berlin: Calendar { CalendarDates.german(timeZone: zone) }
    private let created = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lernfelder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func at(_ d: Int, _ h: Int, _ m: Int = 0) -> Date {
        berlin.date(from: DateComponents(year: 2026, month: 11, day: d, hour: h, minute: m))!
    }

    // MARK: Material catalogue

    static let lessonA = "00000000-0000-4000-8000-0000000000a1"
    static let lessonB = "00000000-0000-4000-8000-0000000000b2"
    static let lessonC = "00000000-0000-4000-8000-0000000000c3"

    private func pdf(_ text: String) -> Data { Data("%PDF-1.4\n% erfunden: \(text)\n%%EOF\n".utf8) }

    private func catalog(scripts: [String: Data]) -> MaterialCatalog {
        func script(_ file: String, pages: Int) -> MaterialScript {
            MaterialScript(file: file, pageCount: pages, byteCount: scripts[file]!.count, sha256: SHA256.hexDigest(scripts[file]!))
        }
        let delivery = MaterialChapter(
            key: "LF03-04", index: 4, number: 4, title: "Die Lieferung", script: script("LF03/Kapitel_4_Lieferung.pdf", pages: 6),
            lessons: [MaterialLesson(id: Self.lessonA, title: "Ort der Lieferung", seconds: 614, order: 1, pages: [2, 3]),
                      MaterialLesson(id: Self.lessonB, title: "Die Werklieferung", seconds: 300, order: 2, pages: [4, 6])],
            units: [MaterialUnit(title: "Ort der Lieferung", pages: [2, 3], headings: ["Beförderung und Versendung"], norms: ["§ 3 Abs. 6 UStG"]),
                    MaterialUnit(title: "Die Werklieferung", pages: [4, 6], headings: ["Abgrenzung Werkleistung"], norms: ["§ 3 Abs. 4 UStG"])],
            pages: [MaterialPage(page: 1, head: "Die Lieferung"),
                    MaterialPage(page: 2, head: "Ort der Lieferung", heading: "Beförderung und Versendung", norms: ["§ 3 Abs. 6 UStG"]),
                    MaterialPage(page: 3, head: "Ort der Lieferung"),
                    MaterialPage(page: 4, head: "Die Werklieferung", heading: "Abgrenzung Werkleistung", norms: ["§ 3 Abs. 4 UStG"]),
                    MaterialPage(page: 5, head: "Die Werklieferung"), MaterialPage(page: 6, head: "Die Werklieferung")])
        let income = MaterialChapter(
            key: "LF04-05", index: 5, number: 5, title: "Einkünfte aus nichtselbständiger Arbeit",
            script: script("LF04/Kapitel_5_Arbeit.pdf", pages: 3),
            lessons: [MaterialLesson(id: Self.lessonC, title: "Werbungskosten", seconds: 700, order: 1, pages: [2, 3])],
            units: [MaterialUnit(title: "Werbungskosten", pages: [2, 3], headings: ["Entfernungspauschale § 9 Abs. 1 Satz 3 Nr. 4 EStG"],
                                 norms: ["§ 9 Abs. 1 EStG", "§ 9a EStG"])],
            pages: [MaterialPage(page: 1, head: "Einkünfte"), MaterialPage(page: 2, head: "Werbungskosten", norms: ["§ 9 Abs. 1 EStG"]),
                    MaterialPage(page: 3, head: "Werbungskosten", heading: "Fahrtenbuchmethode beim Dienstwagen", norms: ["§ 8 Abs. 2 EStG"])])
        return MaterialCatalog(id: "beispiel-material", title: "Beispielmaterial", lessonURL: "https://lernen.example/#/lektion/{id}",
                               fieldURL: "https://lernen.example/#/lernfeld/{id}", created: "2026-11-08",
                               fields: [MaterialField(number: 3, title: "Umsatzsteuer", courseID: "00000000-0000-4000-8000-000000000003",
                                                      chapters: [delivery]),
                                        MaterialField(number: 4, title: "Einkommensteuer", chapters: [income])])
    }

    private var scripts: [String: Data] {
        ["LF03/Kapitel_4_Lieferung.pdf": pdf("Lieferung"), "LF04/Kapitel_5_Arbeit.pdf": pdf("Arbeit")]
    }

    func testCatalogValidatesPathsLimitsAndLinks() throws {
        let valid = catalog(scripts: scripts)
        XCTAssertNoThrow(try valid.validate())
        XCTAssertEqual(valid.lessonLink(Self.lessonA)?.absoluteString, "https://lernen.example/#/lektion/\(Self.lessonA)")
        XCTAssertNil(valid.lessonLink("../evil"), "nur Kennungen in Links")
        for path in ["../x.pdf", "/abs.pdf", "LF03/../x.pdf", "LF03/.hidden.pdf", "LF03/x.txt", "LF03//x.pdf", "LF03/ä.pdf"] {
            XCTAssertFalse(MaterialCatalog.isSafeFile(path), path)
        }
        var broken = valid
        broken.fields[0].chapters[0].lessons[0].pages = [5, 9]
        XCTAssertThrowsError(try broken.validate(), "Seiten außerhalb des Skripts")
        broken = valid; broken.lessonURL = "http://lernen.example/{id}"
        XCTAssertThrowsError(try broken.validate(), "nur https")
        broken = valid; broken.fields[1].chapters[0].key = "LF03-04"
        XCTAssertThrowsError(try broken.validate(), "doppelte Kapitel")
        broken = valid; broken.format = 2
        XCTAssertThrowsError(try broken.validate()) { XCTAssertEqual($0 as? MaterialError, .unsupportedFormat(2)) }
    }

    func testNormsAreReducedToNumberAndLaw() {
        XCTAssertEqual(MaterialSearch.norm("§ 3 Abs. 6 UStG"), .init(number: "3", law: "ustg"))
        XCTAssertEqual(MaterialSearch.norm("§24a EStG"), .init(number: "24a", law: "estg"))
        XCTAssertEqual(MaterialSearch.norm("§ 9 Abs. 1 Satz 3 Nr. 4 EStG"), .init(number: "9", law: "estg"))
        XCTAssertEqual(MaterialSearch.norm("§ 24i SGB V"), .init(number: "24i", law: "sgb v"))
        XCTAssertEqual(MaterialSearch.norm("Abschn. 3.10 Abs. 5 UStAE"), .init(number: "3.10", law: "ustae"))
        XCTAssertNil(MaterialSearch.norm("Die Lieferung"))
    }

    func testSearchFindsLessonsUnitsNormsAndText() throws {
        let catalog = catalog(scripts: scripts)
        let lieferung = MaterialSearch.search("Ort der Lieferung", in: catalog)
        XCTAssertEqual(lieferung.first?.id, "lesson:\(Self.lessonA)", "Lektionstitel zuerst")
        XCTAssertEqual(lieferung.first?.pages, 2...3)
        XCTAssertTrue(lieferung.contains { $0.id == "unit:LF03-04:2" })

        // A norm finds the units and lessons citing it, with the paragraph details.
        let norm = MaterialSearch.search("§ 3 UStG", in: catalog)
        XCTAssertFalse(norm.isEmpty)
        XCTAssertTrue(norm.allSatisfy { $0.field == 3 })
        XCTAssertTrue(norm.contains { $0.norms.contains("§ 3 Abs. 4 UStG") })
        XCTAssertFalse(MaterialSearch.search("9 EStG", in: catalog).isEmpty, "Gesetz aus dem Paket ohne §")

        // A heading inside a page, umlaut-free typing included.
        let fahrtenbuch = MaterialSearch.search("fahrtenbuch", in: catalog)
        XCTAssertEqual(fahrtenbuch.first?.id, "page:LF04-05:3")
        XCTAssertEqual(fahrtenbuch.first?.lessonID, Self.lessonC, "die Lektion zur Seite")
        XCTAssertFalse(MaterialSearch.search("Beforderung", in: catalog).isEmpty)

        // Page text only with the texts file.
        let texts = MaterialTexts(pages: ["LF04/Kapitel_5_Arbeit.pdf": ["", "Die Entfernungspauschale beträgt", ""]])
        XCTAssertTrue(MaterialSearch.search("Pendlerpauschale", in: catalog, texts: texts).isEmpty)
        XCTAssertEqual(MaterialSearch.search("Entfernungspauschale beträgt", in: catalog, texts: texts).first?.chapterKey, "LF04-05")

        // Pinned results first; the Lernfeld of the lesson ranks higher.
        let pinned = MaterialSearch.search("Lieferung", in: catalog, preferred: ["unit:LF03-04:4"])
        XCTAssertEqual(pinned.first?.id, "unit:LF03-04:4")
        XCTAssertTrue(MaterialSearch.search("", in: catalog).isEmpty)
        XCTAssertEqual(MaterialSearch.hit(forKey: "lesson:\(Self.lessonC)", in: catalog)?.title, "Werbungskosten")
        XCTAssertEqual(MaterialSearch.hit(forKey: "unit:LF03-04:4", in: catalog)?.pages, 4...6)
        XCTAssertNil(MaterialSearch.hit(forKey: "page:LF03-04:99", in: catalog))
    }

    // MARK: Package

    private func package(_ entries: [(String, Data)]) throws -> URL {
        let url = root.appendingPathComponent("paket-\(UUID().uuidString).notymaterial")
        try ZipStore.archive(entries.map { (name: $0.0, data: $0.1) }).write(to: url)
        return url
    }

    private func validEntries() throws -> [(String, Data)] {
        let catalog = catalog(scripts: scripts)
        let texts = MaterialTexts(pages: ["LF04/Kapitel_5_Arbeit.pdf": ["a", "b", "c"]])
        return [("catalog.json", try JSONEncoder().encode(catalog)), ("text.json", try JSONEncoder().encode(texts))]
            + scripts.sorted { $0.key < $1.key }.map { ("pdf/" + $0.key, $0.value) }
    }

    func testPackageInstallsCompletelyAndReplacesOnlyAfterChecking() throws {
        let store = MaterialStore(root: root.appendingPathComponent("Materialien", isDirectory: true))
        let installed = try store.install(try package(try validEntries()))
        XCTAssertEqual(installed.catalog.id, "beispiel-material")
        let script = installed.catalog.scripts[0]
        XCTAssertEqual(try Data(contentsOf: installed.scriptURL(script)), scripts[script.file])
        XCTAssertEqual(store.installed().map(\.catalog.id), ["beispiel-material"])
        XCTAssertEqual(store.texts(of: installed)?.pages["LF04/Kapitel_5_Arbeit.pdf"]?.count, 3)

        // A damaged script refuses the whole package; the installed one stays.
        var damaged = try validEntries()
        let index = damaged.firstIndex { $0.0.hasSuffix("Lieferung.pdf") }!
        damaged[index].1 = pdf("verändert!")
        XCTAssertThrowsError(try store.install(try package(damaged))) { XCTAssertEqual($0 as? MaterialError, .checksumMismatch("pdf/LF03/Kapitel_4_Lieferung.pdf")) }
        XCTAssertEqual(try Data(contentsOf: installed.scriptURL(script)), scripts[script.file])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path).filter { $0.hasPrefix(".") }, [], "keine Reste")

        var missing = try validEntries(); missing.removeAll { $0.0.hasSuffix("Arbeit.pdf") }
        XCTAssertThrowsError(try store.install(try package(missing))) { XCTAssertEqual($0 as? MaterialError, .missingFile("pdf/LF04/Kapitel_5_Arbeit.pdf")) }
        var extra = try validEntries(); extra.append(("pdf/LF09/fremd.pdf", pdf("x")))
        XCTAssertThrowsError(try store.install(try package(extra)))
        var traversal = try validEntries(); traversal.append(("pdf/../../evil.pdf", pdf("x")))
        XCTAssertThrowsError(try store.install(try package(traversal)))
        var other = try validEntries(); other.append(("README.txt", Data("x".utf8)))
        XCTAssertThrowsError(try store.install(try package(other)))
        let notZip = root.appendingPathComponent("kein.notymaterial"); try Data("kein zip".utf8).write(to: notZip)
        XCTAssertThrowsError(try store.install(notZip)) { XCTAssertEqual($0 as? MaterialError, .notAPackage) }

        // Installing again replaces the package.
        XCTAssertNoThrow(try store.install(try package(try validEntries())))
        XCTAssertEqual(store.installed().count, 1)
        try store.remove("beispiel-material")
        XCTAssertTrue(store.installed().isEmpty)
    }

    /// Opt-in check of a real (private) package: `NOTY_MATERIAL_PACKAGE=<file>`.
    /// Never part of the repository; skipped without the variable.
    func testRealPackageFromEnvironmentInstallsAndFindsTopics() throws {
        guard let path = ProcessInfo.processInfo.environment["NOTY_MATERIAL_PACKAGE"] else { throw XCTSkip("kein Materialpaket angegeben") }
        let store = MaterialStore(root: root.appendingPathComponent("Echt", isDirectory: true))
        let installed = try store.install(URL(fileURLWithPath: path))
        let texts = store.texts(of: installed)
        XCTAssertNotNil(texts)
        for query in ["Fahrtenbuch", "Lieferung", "Werbungskosten", "§ 15 UStG", "Probezeit", "Kündigung"] {
            let hits = MaterialSearch.search(query, in: installed.catalog, texts: texts)
            XCTAssertFalse(hits.isEmpty, query)
            for hit in hits.prefix(3) {
                let pages = hit.pages.map { "S. \($0.lowerBound)–\($0.upperBound)" } ?? ""
                print("„\(query)“ → \(hit.kind.rawValue) \(hit.location(in: installed.catalog)) · \(hit.title) \(pages)"
                      + (hit.lessonID != nil ? " ▶" : "") + (hit.norms.isEmpty ? "" : " · " + hit.norms.prefix(3).joined(separator: ", ")))
            }
        }
    }

    func testCleanUpKeepsRunningInstallsAndPutsBackAnInterruptedReplacement() throws {
        let store = MaterialStore(root: root.appendingPathComponent("Materialien", isDirectory: true))
        let installed = try store.install(try package(try validEntries()))
        let fm = FileManager.default
        // Interrupted between both renames: only `.old-…` is left.
        let old = store.root.appendingPathComponent(".old-\(UUID().uuidString)", isDirectory: true)
        try fm.moveItem(at: installed.directory, to: old)
        let stage = store.root.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        store.cleanUp(now: Date())
        XTCAssertBoth(fm.fileExists(atPath: stage.path), fm.fileExists(atPath: old.path), "laufende Vorgänge bleiben unberührt")
        store.cleanUp(now: Date().addingTimeInterval(7_200))
        XCTAssertFalse(fm.fileExists(atPath: stage.path))
        XCTAssertEqual(store.installed().map(\.catalog.id), ["beispiel-material"], "unterbrochener Ersatz zurückgelegt")
    }

    private func XTCAssertBoth(_ a: Bool, _ b: Bool, _ message: String) { XCTAssertTrue(a && b, message) }

    // MARK: Study rules and blocks

    func testMostSpecificRuleWins() {
        let lf3 = CalendarStudyField(number: 3, title: "Umsatzsteuer"), lf4 = CalendarStudyField(number: 4, title: "Einkommensteuer")
        let rules = [CalendarStudyRule(subjectKey: "webuntis:sr", subjectName: "SR", fieldID: lf4.id),
                     CalendarStudyRule(subjectKey: "webuntis:sr", subjectName: "SR", weekday: 1, startFrom: 7 * 60, startTo: 10 * 60 + 30, fieldID: lf3.id),
                     CalendarStudyRule(subjectKey: "webuntis:ws", subjectName: "WS", fieldID: lf3.id)]
        func field(_ subject: String, _ date: Date) -> Int? {
            let (weekday, minutes) = CalendarStudy.weekdayAndMinutes(date, timeZone: zone)
            return CalendarStudy.field(subjectKey: subject, weekday: weekday, startMinutes: minutes, rules: rules, fields: [lf3, lf4])?.number
        }
        XCTAssertEqual(field("webuntis:sr", at(9, 8)), 3, "Montag früh: LF 3")      // 9.11.2026 is a Monday
        XCTAssertEqual(field("webuntis:sr", at(9, 11)), 4, "Montag später: LF 4")
        XCTAssertEqual(field("webuntis:sr", at(11, 8)), 4, "Mittwoch: LF 4")
        XCTAssertEqual(field("webuntis:ws", at(11, 8)), 3)
        XCTAssertNil(field("webuntis:de", at(9, 8)))
        XCTAssertEqual(rules[1].label, "SR · Mo · ab 07:00 bis 10:30")
    }

    func testBlockJoinsConsecutiveLessonsOfOneSubject() {
        let lessons: [(subjectKey: String, start: Date, end: Date)] = [
            ("sr", at(9, 8), at(9, 8, 45)), ("sr", at(9, 8, 45), at(9, 9, 30)), ("sr", at(9, 9, 45), at(9, 10, 30)),
            ("de", at(9, 10, 30), at(9, 11, 15)), ("sr", at(9, 13), at(9, 13, 45))]
        XCTAssertEqual(CalendarStudy.block(of: 1, in: lessons), [0, 1, 2], "Pause von 15 Minuten trennt nicht")
        XCTAssertEqual(CalendarStudy.block(of: 4, in: lessons), [4])
        XCTAssertEqual(CalendarStudy.block(of: 3, in: lessons), [3])
    }

    // MARK: Format 5

    private func studyState(notebook: UUID) -> CalendarState {
        var state = CalendarState()
        let field = CalendarStudyField(number: 3, title: "Umsatzsteuer", notebookID: notebook, package: "beispiel-material")
        state.studyFields = [field]
        state.studyRules = [CalendarStudyRule(subjectKey: "webuntis:sr", subjectName: "SR", weekday: 1, startFrom: 420, startTo: 630, fieldID: field.id)]
        let anchor = CalendarLessonAnchor(source: "webuntis:erfunden", periodID: "100", lessonID: nil, originalDate: CivilDate("2026-11-09")!,
                                          originalStart: "2026-11-09T08:00")
        state.lessonTopics = [CalendarLessonTopic(target: .lesson(anchor), topic: "Die Lieferung", summary: "Verfügungsmacht verschaffen",
                                                  materials: [CalendarMaterialRef(package: "beispiel-material", key: "lesson:\(Self.lessonA)",
                                                                                  label: "Ort der Lieferung", detail: "LF 3 · Kapitel 4 · S. 2–3")],
                                                  modifiedAt: created)]
        state.noteLinks = [CalendarNoteLink(target: .lesson(anchor), documentID: notebook, pageID: UUID(), createdAt: created,
                                            contextTitle: "SR", contextStart: at(9, 8), contextEnd: at(9, 10, 30))]
        return state
    }

    func testFormat5RoundTripsAndValidates() async throws {
        let notebook = UUID()
        let state = studyState(notebook: notebook)
        XCTAssertNoThrow(try state.validate())
        let repository = CalendarRepository(areaRoot: root)
        _ = try await repository.load()
        try await repository.save(state, revision: 1)
        await repository.close()
        let reread = try await CalendarRepository(areaRoot: root).load().state
        XCTAssertEqual(reread, state)

        var broken = state; broken.studyRules[0].fieldID = UUID()
        XCTAssertThrowsError(try broken.validate(), "Regel ohne Lernfeld")
        broken = state; broken.studyFields.append(CalendarStudyField(number: 3, title: "Doppelt"))
        XCTAssertThrowsError(try broken.validate(), "Nummer doppelt")
        broken = state; broken.studyFields.append(CalendarStudyField(number: 4, title: "Gleiches Heft", notebookID: notebook))
        XCTAssertThrowsError(try broken.validate(), "zwei Lernfelder, ein Heft")
        broken = state; broken.lessonTopics.append(CalendarLessonTopic(target: state.lessonTopics[0].target, topic: "zweites"))
        XCTAssertThrowsError(try broken.validate(), "ein Thema je Stunde")
        broken = state; broken.studyRules[0].startFrom = 700
        XCTAssertThrowsError(try broken.validate(), "Zeitfenster rückwärts")
        broken = state; broken.lessonTopics[0].materials.append(broken.lessonTopics[0].materials[0])
        XCTAssertThrowsError(try broken.validate(), "Material doppelt")
        broken = state; broken.lessonTopics[0].topic = "zwei\nZeilen"
        XCTAssertThrowsError(try broken.validate())
    }

    func testFormat4MigratesWithExactOldBytesAndRefusesStudyFields() async throws {
        let package = root.appendingPathComponent("Calendar", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
        let bytes = Data(#"{"events":[],"formatVersion":4,"homeworkDone":[{"doneAt":815000000,"homeworkID":"7","source":"webuntis:x"}],"lessonMappings":[],"noteLinks":[],"settings":{"mode":"week","weekDays":5}}"#.utf8)
        let file = UUID().uuidString + ".json"
        try bytes.write(to: package.appendingPathComponent("Revisions/\(file)"))
        let manifest = RevisionManifest(revisions: [RevisionRecord(file: file, byteCount: bytes.count, crc32: SnapshotChecksum.crc32(bytes),
                                                                   savedAtUnix: 1_790_000_000)])
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        let repository = CalendarRepository(areaRoot: root)
        let loaded = try await repository.load()
        XCTAssertEqual(loaded.state.formatVersion, 6)
        XCTAssertEqual(loaded.state.homeworkDone.count, 1)
        var next = loaded.state
        next.studyFields = [CalendarStudyField(number: 1, title: "Rolle im Betrieb")]
        try await repository.save(next, revision: 1)
        await repository.close()
        let archived = try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("Migration").path)
        XCTAssertEqual(archived.count, 1)
        XCTAssertTrue(archived[0].hasPrefix("format-4-"))
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("Migration/\(archived[0])")), bytes, "exakte Altbytes")

        // Format 4 with study fields is not format 4; format 7 locks.
        let mixed = Data(#"{"events":[],"formatVersion":4,"studyFields":[{"id":"00000000-0000-4000-8000-000000000001","number":1,"title":"x"}]}"#.utf8)
        XCTAssertThrowsError(try CalendarStore.decode(mixed))
        XCTAssertThrowsError(try CalendarStore.decode(Data(#"{"events":[],"formatVersion":7}"#.utf8))) {
            XCTAssertEqual($0 as? CalendarStoreError, .unsupportedFormat(7))
        }
    }

    // MARK: Format 6: Fach-Hefte

    func testFormat6SubjectNotebooksRoundTripAndValidate() async throws {
        let lernfeld = UUID(), religion = UUID()
        var state = studyState(notebook: lernfeld)
        state.subjectNotebooks = [CalendarSubjectNotebook(subjectKey: "webuntis:rel", subjectName: "Religion", notebookID: religion)]
        XCTAssertNoThrow(try state.validate())
        let repository = CalendarRepository(areaRoot: root)
        _ = try await repository.load()
        try await repository.save(state, revision: 1)
        await repository.close()
        let reread = try await CalendarRepository(areaRoot: root).load().state
        XCTAssertEqual(reread, state)
        XCTAssertEqual(reread.formatVersion, 6)

        var broken = state
        broken.subjectNotebooks.append(CalendarSubjectNotebook(subjectKey: "webuntis:rel", subjectName: "Reli 2", notebookID: UUID()))
        XCTAssertThrowsError(try broken.validate(), "ein Heft je Fach")
        broken = state; broken.subjectNotebooks.append(CalendarSubjectNotebook(subjectKey: "webuntis:eth", subjectName: "Ethik", notebookID: religion))
        XCTAssertThrowsError(try broken.validate(), "ein Fach je Heft")
        broken = state; broken.subjectNotebooks[0].notebookID = lernfeld
        XCTAssertThrowsError(try broken.validate(), "kein Lernfeld-Heft")
        broken = state; broken.subjectNotebooks[0].subjectName = " "
        XCTAssertThrowsError(try broken.validate())
        XCTAssertEqual(CalendarStudy.subjectNotebook(subjectKey: "webuntis:rel", in: state.subjectNotebooks)?.notebookID, religion)
        XCTAssertNil(CalendarStudy.subjectNotebook(subjectKey: "webuntis:sr", in: state.subjectNotebooks))
        // Without Fach-Hefte the state is written exactly as format 5 wrote it (no key).
        var plain = state; plain.subjectNotebooks = []
        XCTAssertFalse(String(decoding: try CalendarStore.encoder.encode(plain), as: UTF8.self).contains("subjectNotebooks"))
    }

    func testFormat5MigratesWithExactOldBytesAndRefusesSubjectNotebooks() async throws {
        let package = root.appendingPathComponent("Calendar", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Revisions"), withIntermediateDirectories: true)
        var old = studyState(notebook: UUID()); old.formatVersion = 5
        let bytes = try CalendarStore.encoder.encode(old)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains(#""formatVersion":5"#))
        let file = UUID().uuidString + ".json"
        try bytes.write(to: package.appendingPathComponent("Revisions/\(file)"))
        let manifest = RevisionManifest(revisions: [RevisionRecord(file: file, byteCount: bytes.count, crc32: SnapshotChecksum.crc32(bytes),
                                                                   savedAtUnix: 1_790_000_000)])
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("manifest.json"))
        let repository = CalendarRepository(areaRoot: root)
        let loaded = try await repository.load()
        XCTAssertEqual(loaded.state.formatVersion, 6)
        XCTAssertEqual(loaded.state.studyFields, old.studyFields)
        XCTAssertEqual(loaded.state.lessonTopics, old.lessonTopics)
        var next = loaded.state
        next.subjectNotebooks = [CalendarSubjectNotebook(subjectKey: "webuntis:rel", subjectName: "Religion", notebookID: UUID())]
        try await repository.save(next, revision: 1)
        await repository.close()
        let archived = try FileManager.default.contentsOfDirectory(atPath: package.appendingPathComponent("Migration").path)
        XCTAssertEqual(archived.count, 1)
        XCTAssertTrue(archived[0].hasPrefix("format-5-"))
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("Migration/\(archived[0])")), bytes, "exakte Altbytes")
        let migrated = try await CalendarRepository(areaRoot: root).load().state
        XCTAssertEqual(migrated, next)

        // Format 5 with a Fach-Heft is not format 5.
        let mixed = Data(#"{"events":[],"formatVersion":5,"subjectNotebooks":[{"id":"00000000-0000-4000-8000-000000000001","subjectKey":"webuntis:rel","subjectName":"Religion","notebookID":"00000000-0000-4000-8000-000000000002"}]}"#.utf8)
        XCTAssertThrowsError(try CalendarStore.decode(mixed))
    }

    func testArchiveCarriesSubjectNotebooksRemapsAndDropsDeletedOnes() async throws {
        let lernfeld = UUID(), religion = UUID(), copy = UUID(), copy2 = UUID()
        var state = studyState(notebook: lernfeld)
        state.subjectNotebooks = [CalendarSubjectNotebook(subjectKey: "webuntis:rel", subjectName: "Religion", notebookID: religion)]
        let bytes = try CalendarArchive.encodeState(state)
        XCTAssertEqual(try CalendarArchive.decodeState(bytes), state)
        let restored = try CalendarArchive.restored(CalendarArchiveContent(state: state), documents: [lernfeld: copy, religion: copy2], folders: [:])
        XCTAssertEqual(restored.state.subjectNotebooks[0].notebookID, copy2)
        XCTAssertEqual(restored.state.studyFields[0].notebookID, copy)
        XCTAssertThrowsError(try CalendarArchive.restored(CalendarArchiveContent(state: state), documents: [lernfeld: copy], folders: [:])) {
            XCTAssertEqual($0 as? CalendarArchiveError, .danglingReference)
        }
        XCTAssertThrowsError(try CalendarArchiveContent(state: state).validate(documents: [lernfeld], folders: []))
        XCTAssertNoThrow(try CalendarArchiveContent(state: state).validate(documents: [lernfeld, religion], folders: []))

        // Backup of an area whose Religion notebook is deleted for good: the subject chooses anew, the field keeps its notebook.
        let repository = CalendarRepository(areaRoot: root)
        _ = try await repository.load()
        try await repository.save(state, revision: 1)
        await repository.close()
        var library = LibrarySnapshot()
        library.items = [LibraryItem(id: lernfeld, title: "LF 3", parentID: nil, source: .library)]
        let capture = try CalendarArchive.capture(areaRoot: root, library: library)
        XCTAssertEqual(capture.content?.state.subjectNotebooks, [])
        XCTAssertEqual(capture.content?.state.studyFields[0].notebookID, lernfeld)
    }

    func testArchiveCarriesStudyDataAndRemapsTheFieldNotebook() throws {
        let notebook = UUID(), copy = UUID()
        let state = studyState(notebook: notebook)
        let bytes = try CalendarArchive.encodeState(state)
        XCTAssertEqual(try CalendarArchive.decodeState(bytes), state)
        let restored = try CalendarArchive.restored(CalendarArchiveContent(state: state), documents: [notebook: copy], folders: [:])
        XCTAssertEqual(restored.state.studyFields[0].notebookID, copy)
        XCTAssertEqual(restored.state.noteLinks[0].documentID, copy)
        XCTAssertEqual(restored.state.lessonTopics, state.lessonTopics)
        XCTAssertThrowsError(try CalendarArchive.restored(CalendarArchiveContent(state: state), documents: [:], folders: [:])) {
            XCTAssertEqual($0 as? CalendarArchiveError, .danglingReference)
        }
        XCTAssertThrowsError(try CalendarArchiveContent(state: state).validate(documents: [], folders: []))
    }

    // MARK: Sections of a Lernfeld notebook

    func testSectionPagesGoInChronologicalOrder() throws {
        var notebook = Notebook.blank(title: "LF 3 – Umsatzsteuer")
        let first = notebook.pages[0].id
        func link(_ page: UUID, day: Int, period: String) -> CalendarNoteLink {
            let date = String(format: "2026-11-%02d", day)
            let anchor = CalendarLessonAnchor(source: "webuntis:x", periodID: period, lessonID: nil, originalDate: CivilDate(date)!,
                                              originalStart: date + "T08:00")
            return CalendarNoteLink(target: .lesson(anchor), documentID: notebook.id, pageID: page, createdAt: created,
                                    contextTitle: "SR", contextStart: at(day, 8), contextEnd: at(day, 10, 30))
        }
        var links: [CalendarNoteLink] = []
        XCTAssertEqual(StudySections.insertionIndex(for: at(9, 8), in: notebook, sections: []), 1, "ans Ende ohne Abschnitte")

        let heading = StudySections.heading(subject: "SR", start: at(9, 8), end: at(9, 10, 30), topic: "Die Lieferung", timeZone: zone)
        XCTAssertEqual(heading, "Mo 09.11.2026 · SR · 08:00–10:30 – Die Lieferung")
        let monday = try notebook.insertSectionPage(heading: heading, at: 1)
        links.append(link(monday, day: 9, period: "1"))
        XCTAssertEqual(notebook.pages[1].textBoxes?.first?.text, heading)
        XCTAssertEqual(notebook.pages[1].textBoxes?.first?.style.bold, true)
        _ = try notebook.insertPaper(.lined, at: 2)          // a second page of Monday's section

        var sections = StudySections.sections(of: notebook, links: links)
        XCTAssertEqual(sections.map(\.pageIDs.count), [2])
        let wednesday = try notebook.insertSectionPage(heading: "Mi", at: StudySections.insertionIndex(for: at(11, 8), in: notebook, sections: sections))
        links.append(link(wednesday, day: 11, period: "2"))
        sections = StudySections.sections(of: notebook, links: links)
        // Catching up a lesson between both goes between them, after Monday's second page.
        let tuesdayIndex = StudySections.insertionIndex(for: at(10, 8), in: notebook, sections: sections)
        XCTAssertEqual(tuesdayIndex, 3)
        let tuesday = try notebook.insertSectionPage(heading: "Di", at: tuesdayIndex)
        links.append(link(tuesday, day: 10, period: "3"))
        sections = StudySections.sections(of: notebook, links: links, topics: [CalendarLessonTopic(target: links[0].target, topic: "Die Lieferung")])
        XCTAssertEqual(sections.map(\.headingPageID), [monday, tuesday, wednesday])
        XCTAssertEqual(sections[0].topic, "Die Lieferung")
        XCTAssertEqual(notebook.pages.first?.id, first, "Seiten vor dem ersten Abschnitt bleiben vorn")
        XCTAssertEqual(StudySections.section(containing: notebook.pages[2].id, in: sections)?.headingPageID, monday)
        // An earlier lesson than all: before the first section.
        XCTAssertEqual(StudySections.insertionIndex(for: at(2, 8), in: notebook, sections: sections), 1)
        // A link to a page that no longer exists is left out.
        links.append(CalendarNoteLink(target: .local(event: UUID(), date: nil), documentID: notebook.id, pageID: UUID(), createdAt: created,
                                      contextTitle: "x", contextStart: at(12, 8), contextEnd: at(12, 9)))
        XCTAssertEqual(StudySections.sections(of: notebook, links: links).count, 3)
        XCTAssertNoThrow(try notebook.validate())
    }
}
