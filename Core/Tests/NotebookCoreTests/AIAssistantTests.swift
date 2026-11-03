import Foundation
import XCTest
@testable import NotebookCore

final class AIAssistantTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }
    private func box(_ text: String, y: Double = 40) -> TextBox {
        TextBox(id: UUID(), x: 40, y: y, width: 400, height: 80, text: text, style: TextBoxStyle(color: .black))
    }
    private func page(_ text: String...) -> Page {
        var page = Page(); page.geometry = PaperStyle.geometry
        page.textBoxes = text.enumerated().map { box($1, y: 40 + Double($0) * 100) }
        return page
    }
    private func notebook(_ pages: [Page]) -> Notebook {
        var notebook = Notebook(); notebook.schemaVersion = Notebook.currentSchemaVersion; notebook.pages = pages
        return notebook
    }
    private func line(_ text: String, _ kind: SearchContentKind) -> SearchLine {
        SearchLine(text: text, kind: kind, bounds: PageRect(x: 0, y: 0, width: 10, height: 10))
    }
    private func input(_ number: Int, _ text: String) -> AIContextPage {
        AIContextPage(number: number, pageID: UUID(), text: [line(text, .text)])
    }

    // MARK: Contract types

    func testDecodesSessionAndSummaryAsInTheContract() throws {
        let id = UUID()
        let session = try decode(AISession.self, """
        { "id": "s1", "documentId": "\(id.uuidString.lowercased())", "title": "Mathe", "status": "running", "revision": 7,
          "updatedAt": 1790000000123, "extra": true,
          "messages": [{ "id": "m1", "role": "user", "text": "Was?", "contextLabel": "Mathe, Seite 3", "imageCount": 1 },
                       { "id": "m2", "role": "assistant", "text": "So. [S. 3]" },
                       { "id": "m3", "role": "system", "text": "Hinweis" }] }
        """)
        XCTAssertEqual(session.status, .running)
        XCTAssertEqual(session.messages.map(\.role), [.user, .assistant, .system])
        XCTAssertEqual(session.messages[0].imageCount, 1)
        XCTAssertNil(session.messages[1].contextLabel)
        XCTAssertTrue(session.belongs(to: id), "UUID-Schreibweise darf keine Rolle spielen")
        XCTAssertFalse(session.belongs(to: UUID()))
        XCTAssertEqual(session.summary.updatedDate.timeIntervalSince1970, 1_790_000_000.123, accuracy: 0.001)

        let list = try decode([AISessionSummary].self, """
        [{ "id": "s1", "documentId": null, "title": null, "status": "interrupted", "revision": 0, "updatedAt": 5 }]
        """)
        XCTAssertEqual(list.first?.status, .interrupted)
        XCTAssertNil(list.first?.title)
    }

    func testDecodesInfoAndUsage() throws {
        let info = try decode(AIInfo.self, """
        { "account": null, "models": [{ "id": "a", "name": "A", "isDefault": true }],
          "limits": { "maxImages": 4, "maxImageBytes": 4194304, "maxContextChars": 200000, "maxQuestionChars": 20000, "dailyTurns": 200, "usedToday": 12 } }
        """)
        XCTAssertNil(info.account)
        XCTAssertEqual(info.limits.usedToday, 12)
        XCTAssertEqual(info.limits.maxImageBytes, AILimits.contract.maxImageBytes)

        let usage = try decode(AIUsage.self, """
        { "checkedAt": 1790000000000, "limits": [
          { "id": "codex", "name": null, "windows": [
            { "usedPercent": 12.5, "windowDurationMins": 300, "resetsAt": 1790003600 },
            { "usedPercent": 3, "windowDurationMins": null, "resetsAt": "2026-11-02T10:00:00.500Z" },
            { "usedPercent": 0, "windowDurationMins": 60, "resetsAt": null }] }] }
        """)
        let windows = usage.limits[0].windows
        XCTAssertEqual(usage.checkedAt?.date.timeIntervalSince1970, 1_790_000_000)
        XCTAssertEqual(windows[0].resetsAt?.date.timeIntervalSince1970, 1_790_003_600, "Sekunden und Millisekunden ergeben denselben Zeitpunkt")
        XCTAssertNotNil(windows[1].resetsAt)
        XCTAssertNil(windows[1].windowDurationMins)
        XCTAssertNil(windows[2].resetsAt)
    }

    func testTurnRequestLeavesOutWhatIsNotSent() throws {
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AITurnRequest(requestId: "abcdefgh-1", text: "Frage"))) as? [String: Any]
        XCTAssertEqual(Set(plain?.keys ?? [:].keys), ["requestId", "text"])

        let full = AITurnRequest(requestId: "abcdefgh-2", text: "Frage", context: AITurnContext(label: "Mathe, Seite 3", text: "…"),
                                 images: [AITurnImage(mimeType: "image/jpeg", base64: "AAAA", label: "Seite 3")], model: "m", effort: "low")
        let round = try JSONDecoder().decode(AITurnRequest.self, from: JSONEncoder().encode(full))
        XCTAssertEqual(round, full)
    }

    func testRequestIDAndLimits() {
        XCTAssertTrue(AITurnRequest.isValidRequestID(UUID().uuidString))
        for bad in ["kurz", String(repeating: "a", count: 81), "mit leerzeichen", "äöü-äöü-äöü"] {
            XCTAssertFalse(AITurnRequest.isValidRequestID(bad), bad)
        }
        var limits = AILimits.contract
        limits.maxQuestionChars = 4; limits.maxContextChars = 4; limits.maxImages = 1; limits.maxImageBytes = 3
        func violation(_ request: AITurnRequest) -> String? { request.violation(of: limits) }
        let image = AITurnImage(mimeType: "image/jpeg", base64: "AAAA", label: "S")
        XCTAssertNil(violation(AITurnRequest(text: "Frag", context: AITurnContext(label: "L", text: "1234"), images: [image])))
        XCTAssertNotNil(violation(AITurnRequest(text: "  \n")))
        XCTAssertNotNil(violation(AITurnRequest(text: "Frage")))
        // Ein Emoji zählt wie beim Server als zwei Einheiten.
        XCTAssertNotNil(violation(AITurnRequest(text: "abc😀")))
        XCTAssertNotNil(violation(AITurnRequest(text: "Ok", context: AITurnContext(label: "L", text: "12345"))))
        XCTAssertNotNil(violation(AITurnRequest(text: "Ok", images: [image, image])))
        XCTAssertNotNil(violation(AITurnRequest(text: "Ok", images: [AITurnImage(mimeType: "image/jpeg", base64: "AAAAAA==", label: "S")])))
        XCTAssertNotNil(violation(AITurnRequest(text: "Ok", images: [AITurnImage(mimeType: "image/gif", base64: "AAAA", label: "S")])))
    }

    func testImageSizeComesFromBase64WithoutDecoding() {
        for count in 0...7 {
            let base64 = Data(repeating: 1, count: count).base64EncodedString()
            XCTAssertEqual(AITurnImage(mimeType: "image/png", base64: base64, label: "").byteCount, count)
        }
    }

    // MARK: Account

    func testDecodesMeAndCountsMissingCountersAsZero() throws {
        let me = try decode(AIMe.self, """
        { "user": { "id": "u1", "name": "Leon" }, "status": "pending", "role": "user", "dailyLimit": null,
          "today": { "turns": 3, "failedTurns": 1, "images": 2, "inputTokens": 10, "cachedInputTokens": 4, "outputTokens": 5, "reasoningOutputTokens": 6 } }
        """)
        XCTAssertEqual(me.status, .pending)
        XCTAssertEqual(me.user.name, "Leon")
        XCTAssertNil(me.dailyLimit)
        XCTAssertEqual(me.today.turns, 3)
        XCTAssertEqual(me.today.reasoningOutputTokens, 6)
        let quiet = try decode(AIMe.self, """
        { "user": { "id": "u1", "name": "Leon" }, "status": "active", "role": "admin", "dailyLimit": 0, "today": {} }
        """)
        XCTAssertEqual(quiet.today, AIUsageCounters())
    }

    func testRejectionsComeFromStatusAndCode() throws {
        func rejection(_ status: Int, _ json: String) throws -> AIAccessRejection? {
            AIAccessRejection(status: status, code: try decode(AIErrorReply.self, json).code)
        }
        XCTAssertEqual(try rejection(401, #"{ "error": "Bitte anmelden." }"#), .unauthorized)
        XCTAssertEqual(try rejection(403, #"{ "error": "Wartet.", "code": "pending" }"#), .pending)
        XCTAssertEqual(try rejection(403, #"{ "error": "Gesperrt.", "code": "blocked" }"#), .blocked)
        XCTAssertNil(try rejection(403, #"{ "error": "Etwas anderes." }"#))
        XCTAssertNil(try rejection(429, #"{ "error": "Limit." }"#))
        XCTAssertNil(try rejection(503, #"{ "error": "Konto nicht erreichbar.", "code": "pending" }"#))
    }

    func testAccessNamesTheReasonAndBlocksSending() throws {
        func me(_ status: String, limit: String = "null") throws -> AIMe {
            try decode(AIMe.self, """
            { "user": { "id": "u", "name": "n" }, "status": "\(status)", "dailyLimit": \(limit), "today": {} }
            """)
        }
        func access(server: Bool = true, signedIn: Bool = true, expired: Bool = false, me: AIMe? = nil, rejection: AIAccessRejection? = nil) -> AIAccess {
            .resolve(hasServer: server, signedIn: signedIn, sessionExpired: expired, me: me, rejection: rejection)
        }
        XCTAssertEqual(access(signedIn: false), .signedOut)
        XCTAssertEqual(access(server: false, signedIn: false), .signedOut, "Ohne Konto hilft auch keine Adresse")
        XCTAssertEqual(access(server: false), .noServer)
        XCTAssertEqual(access(expired: true, me: try me("active")), .expired)
        XCTAssertEqual(access(me: try me("active"), rejection: .unauthorized), .expired)
        XCTAssertEqual(access(me: try me("pending")), .pending)
        XCTAssertEqual(access(me: try me("blocked")), .blocked)
        XCTAssertEqual(access(me: try me("active"), rejection: .blocked), .blocked, "403 ist neuer als der letzte Status")
        XCTAssertEqual(access(me: try me("active"), rejection: .pending), .pending)
        XCTAssertEqual(access(me: try me("active", limit: "0")), .noRuns)
        XCTAssertEqual(access(me: try me("active", limit: "5")), .open)
        XCTAssertEqual(access(), .open, "Noch ohne Antwort von /v1/me")
        for blocked in [AIAccess.noServer, .signedOut, .expired, .pending, .blocked, .noRuns] {
            XCTAssertFalse(blocked.canSend)
            XCTAssertNotNil(blocked.reason)
        }
        XCTAssertTrue(AIAccess.open.canSend)
        XCTAssertNil(AIAccess.open.reason)
    }

    // MARK: Server address

    func testServerAddressIsNormalised() {
        XCTAssertEqual(AIServerAddress.parse("https://noty-ai.tail1234.ts.net:8443")?.absoluteString, "https://noty-ai.tail1234.ts.net:8443")
        XCTAssertEqual(AIServerAddress.parse("  https://server.ts.net\n")?.absoluteString, "https://server.ts.net")
        XCTAssertEqual(AIServerAddress.parse("HTTPS://Server.TS.net/")?.absoluteString, "https://server.ts.net")
        XCTAssertEqual(AIServerAddress.parse("https://100.64.0.1:8443")?.port, 8443)
    }

    func testServerAddressRejectsEverythingElse() {
        for input in ["", "   ", "server.ts.net", "http://server.ts.net", "ftp://server", "https://", "https://server.ts.net:0",
                      "https://server.ts.net:70000", "https://user@server.ts.net", "https://user:pw@server.ts.net",
                      "https://@server.ts.net", "https://server.ts.net/pfad", "https://server.ts.net/v1/", "https://server.ts.net?x=1",
                      "https://server.ts.net#code", "https://ser ver.ts.net", "https://server..net", "https://-server.net",
                      "https://server.ts.net.", "https://evil.example%2Fserver", "javascript:alert(1)"] {
            XCTAssertNil(AIServerAddress.parse(input), input)
        }
    }

    // MARK: Context

    func testContextUsesPageHeadersAndAllRecognizedLayers() {
        var first = input(1, "Getippt")
        first.pdfText = [line("Aus dem PDF", .pdf)]
        first.imageOCR = [line("Aus dem PDF", .image), line("Aus dem Scan", .image)]
        first.handwriting = [line("Handschrift", .handwriting)]
        let context = AIContextBuilder.build([first, AIContextPage(number: 2, pageID: UUID()), input(3, "Drei")])
        XCTAssertEqual(context.text, """
        --- Seite 1 ---
        Getippt

        Aus dem PDF

        Aus dem Scan

        Handschrift

        --- Seite 3 ---
        Drei
        """)
        XCTAssertEqual(context.includedPages, [1, 3])
        XCTAssertEqual(context.pageCount, 3)
        XCTAssertFalse(context.wasTruncated)
        XCTAssertNil(context.truncationNotice)
    }

    func testLongTextBoxLosesOnlyItsChunkOverlap() throws {
        let original = (0..<9_000).map { String($0 % 10) }.joined()
        let notebook = notebook([page(original)])
        XCTAssertGreaterThan(ContentSearchPlanner.textLines(notebook.pages[0]).count, 1, "Voraussetzung: mehrere Abschnitte")
        let pages = AIContextBuilder.pages(of: notebook, index: nil)
        XCTAssertEqual(AIContextBuilder.build(pages).text, "--- Seite 1 ---\n" + original)
    }

    func testRepeatedTextIsNotTakenForOverlap() {
        // Same text in two boxes: both stay.
        let notebook = notebook([page("Wiederholung", "Wiederholung")])
        let text = AIContextBuilder.build(AIContextBuilder.pages(of: notebook, index: nil)).text
        XCTAssertEqual(text, "--- Seite 1 ---\nWiederholung\n\nWiederholung")
        // Exactly one chunk long, separate box at the same place: not a continuation.
        let chunk = String(repeating: "a", count: 2_000)
        let bounds = PageRect(x: 0, y: 0, width: 1, height: 1)
        let lines = [SearchLine(text: chunk, kind: .text, bounds: bounds), SearchLine(text: "anders", kind: .text, bounds: bounds)]
        XCTAssertEqual(AIContextBuilder.typedBlocks(lines), [chunk, "anders"])
    }

    func testPagesReuseOnlyValidLayersOfTheIndex() {
        var book = notebook([page("Eins"), page("Zwei")])
        book.pages[1].drawing = Data([1, 2, 3])
        let prepared = ContentSearchPlanner.prepare(book)
        var index = ContentSearchPlanner.reconcile(nil, documentID: book.id, pages: prepared)
        index.pages[1].handwriting = SearchLayerRecord(fingerprint: prepared[1].fingerprints.handwriting!, lines: [line("erkannt", .handwriting)])

        var pages = AIContextBuilder.pages(of: book, index: index)
        XCTAssertEqual(pages[1].handwriting.map(\.text), ["erkannt"])
        XCTAssertFalse(pages[1].needsRecognition)
        XCTAssertEqual(AIContextBuilder.build(pages).unrecognizedPages, [])

        // Changed ink: the old text must not go out as the page's content.
        book.pages[1].drawing = Data([9, 9, 9])
        pages = AIContextBuilder.pages(of: book, index: index)
        XCTAssertTrue(pages[1].handwriting.isEmpty)
        XCTAssertTrue(pages[1].needsRecognition)
        let context = AIContextBuilder.build(pages)
        XCTAssertEqual(context.unrecognizedPages, [2])
        XCTAssertTrue(context.text.contains("[noty:"), "Auch das Modell erfährt, was fehlt")
        XCTAssertFalse(context.text.contains("erkannt\n"))
    }

    func testIndexOfAnotherNotebookIsIgnored() {
        let book = notebook([page("Eins")])
        let other = SearchDocumentIndex(documentID: UUID(), pages: [SearchPageRecord(pageID: book.pages[0].id, text: [line("Fremd", .text)])])
        let text = AIContextBuilder.build(AIContextBuilder.pages(of: book, index: other)).text
        XCTAssertFalse(text.contains("Fremd"))
    }

    func testEmptyInkAndSinglePageSelection() {
        var book = notebook([page("Eins"), page("Zwei")])
        book.pages[0].drawing = Data([0])
        let target = book.pages[1].id
        XCTAssertEqual(AIContextBuilder.pages(of: book, index: nil, only: target).map(\.number), [2])
        XCTAssertTrue(AIContextBuilder.pages(of: book, index: nil)[0].needsRecognition)
        XCTAssertFalse(AIContextBuilder.pages(of: book, index: nil, drawingIsEmpty: { _ in true })[0].needsRecognition)
    }

    func testPDFTextReadNowFillsTheMissingLayerAndMakesOCRUnnecessary() {
        var scanned = AIContextPage(number: 1, pageID: UUID(), missing: [.pdfText, .imageOCR])
        XCTAssertTrue(scanned.needsRecognition)
        var exact = scanned
        exact.fillPDFText("Ein ausreichend langer Text\naus der Textebene dieser PDF-Seite")
        XCTAssertEqual(exact.missing, [.imageOCR])
        XCTAssertFalse(exact.needsRecognition, "Mit Textebene fehlt ohne eingefügte Bilder nichts")
        exact.hasImages = true
        XCTAssertTrue(exact.needsRecognition)
        scanned.fillPDFText("")
        XCTAssertTrue(scanned.needsRecognition, "Ein Scan ohne Textebene bleibt unerkannt")
        XCTAssertEqual(AIContextBuilder.build([exact]).text.components(separatedBy: "\n").prefix(3),
                       ["--- Seite 1 ---", "Ein ausreichend langer Text", "aus der Textebene dieser PDF-Seite"])
    }

    func testLimitCutsOnePageAndNamesTheMissingOnes() {
        let long = String(repeating: "x", count: 1_000)
        let pages = (1...6).map { input($0, long) }
        let context = AIContextBuilder.build(pages, limit: 2_800)
        XCTAssertLessThanOrEqual(context.text.utf16.count, 2_800)
        XCTAssertEqual(context.includedPages, [1, 2, 3])
        XCTAssertEqual(context.truncatedPage, 3)
        XCTAssertEqual(context.omittedPages, [4, 5, 6])
        XCTAssertTrue(context.wasTruncated)
        XCTAssertEqual(context.truncationNotice, "Gekürzt: Seite 3 nur teilweise, 3 Seiten fehlen (4–6).")
        XCTAssertTrue(context.text.hasSuffix("[noty: Gekürzt: Seite 3 nur teilweise, 3 Seiten fehlen (4–6).]"))
    }

    func testPageThatBarelyStartsCountsAsMissing() {
        let long = String(repeating: "x", count: 1_000)
        let context = AIContextBuilder.build([input(1, long), input(2, long)], limit: 1_500)
        XCTAssertNil(context.truncatedPage)
        XCTAssertEqual(context.omittedPages, [2])
        XCTAssertEqual(context.truncationNotice, "Gekürzt: 1 Seite fehlt (2).")
    }

    func testLimitIsNeverExceeded() {
        let text = String(repeating: "Wort 😀 ", count: 400)
        let pages = (1...40).map { input($0, text) }
        for limit in [0, 1, 50, 399, 400, 401, 600, 999, 1_000, 3_333, 10_001, 200_000] {
            let context = AIContextBuilder.build(pages, limit: limit)
            XCTAssertLessThanOrEqual(context.text.utf16.count, limit, "Grenze \(limit)")
            XCTAssertEqual(context.includedPages.count + context.omittedPages.count, 40, "Grenze \(limit): keine Seite geht verloren")
            if limit < 40_000 { XCTAssertTrue(context.wasTruncated, "Grenze \(limit)") }
        }
    }

    func testCutNeverSplitsACharacter() throws {
        let context = AIContextBuilder.build([input(1, String(repeating: "😀", count: 900))], limit: 1_001)
        XCTAssertNotNil(context.truncatedPage)
        let body = try XCTUnwrap(context.text.components(separatedBy: "\n").dropFirst().first)
        XCTAssertFalse(body.isEmpty)
        XCTAssertEqual(body.utf16.count % 2, 0, "Kein halbes Emoji am Schnitt")
        XCTAssertTrue(body.unicodeScalars.allSatisfy { $0 == "😀" })
    }

    func testEmptyPagesSendNoContext() {
        let context = AIContextBuilder.build([AIContextPage(number: 1, pageID: UUID(), missing: [.handwriting])])
        XCTAssertTrue(context.isEmpty)
        XCTAssertEqual(context.text, "", "Ein Hinweis allein ist kein Kontext")
        XCTAssertEqual(context.unrecognizedPages, [1])
    }

    func testLabelStaysWithinTheServerLimit() {
        XCTAssertEqual(AIContextBuilder.label(title: "Mathe", place: "Seite 3"), "Mathe, Seite 3")
        XCTAssertEqual(AIContextBuilder.label(title: "  ", place: "Seite 3"), "Seite 3")
        let long = AIContextBuilder.label(title: String(repeating: "😀", count: 300), place: "ganzes Heft")
        XCTAssertLessThanOrEqual(long.utf16.count, 200)
        XCTAssertTrue(long.hasSuffix(", ganzes Heft"))
    }

    func testPageList() {
        XCTAssertEqual(AIContextBuilder.pageList([]), "")
        XCTAssertEqual(AIContextBuilder.pageList([3]), "3")
        XCTAssertEqual(AIContextBuilder.pageList([9, 5, 6, 7, 8, 3, 12]), "3, 5–9, 12")
        XCTAssertEqual(AIContextBuilder.pageList(Array(stride(from: 1, through: 41, by: 2))), "1, 3, 5, 7, 9, 11, 13, 15 …")
    }

    // MARK: Citations

    private func pages(_ count: Int) -> Set<Int> { count > 0 ? Set(1...count) : [] }

    func testCitationsSplitAnswer() {
        XCTAssertEqual(AICitation.parts(in: "Siehe [S. 3] und [S. 12].", pages: pages(12)), [
            .text("Siehe "), .citation(page: 3, label: "[S. 3]"), .text(" und "), .citation(page: 12, label: "[S. 12]"), .text("."),
        ])
        XCTAssertEqual(AICitation.parts(in: "[S. 1]", pages: pages(1)), [.citation(page: 1, label: "[S. 1]")])
        XCTAssertEqual(AICitation.parts(in: "", pages: pages(3)), [])
    }

    func testForeignNumbersStayText() {
        for text in ["Siehe [S. 13] dort", "[S. 0]", "[S. -1]", "[S. x]", "[S. ]", "[S. 3", "[S. 99999999999999999999]", "[S. ٣]", "[s. 3]", "[S.3]",
                     "[S. 1,]", "[S. 1, ]", "[S. 1 oder 3]", "[S. 1, x]", "[S. 1 und 3"] {
            XCTAssertEqual(AICitation.parts(in: text, pages: pages(12)), [.text(text)], text)
        }
        XCTAssertEqual(AICitation.parts(in: "[S. 1]", pages: []), [.text("[S. 1]")])
        XCTAssertEqual(AICitation.parts(in: "[S. [S. 2]", pages: pages(3)), [.text("[S. "), .citation(page: 2, label: "[S. 2]")])
    }

    func testOnlyListedPagesBecomeCitations() {
        XCTAssertEqual(AICitation.parts(in: "[S. 2] und [S. 3]", pages: [3]), [.text("[S. 2] und "), .citation(page: 3, label: "[S. 3]")])
    }

    func testCitationWithSeveralPages() {
        XCTAssertEqual(AICitation.parts(in: "Siehe [S. 1, 3].", pages: pages(3)), [
            .text("Siehe "), .citation(page: 1, label: "[S. 1]"), .text(", "), .citation(page: 3, label: "[3]"), .text("."),
        ])
        XCTAssertEqual(AICitation.parts(in: "[S. 1 und 3]", pages: pages(3)), [
            .citation(page: 1, label: "[S. 1]"), .text(" und "), .citation(page: 3, label: "[3]"),
        ])
        XCTAssertEqual(AICitation.parts(in: "[S. 1, 2 und 3]", pages: pages(3)), [
            .citation(page: 1, label: "[S. 1]"), .text(", "), .citation(page: 2, label: "[2]"), .text(" und "), .citation(page: 3, label: "[3]"),
        ])
        XCTAssertEqual(AICitation.parts(in: "[S. 1,3]", pages: pages(3)), [
            .citation(page: 1, label: "[S. 1]"), .text(","), .citation(page: 3, label: "[3]"),
        ])
    }

    func testSeveralPagesKeepForeignNumbersAsText() {
        XCTAssertEqual(AICitation.parts(in: "[S. 1, 99]", pages: pages(3)), [.citation(page: 1, label: "[S. 1]"), .text(", 99")])
        XCTAssertEqual(AICitation.parts(in: "[S. 99, 3]", pages: pages(3)), [.text("S. 99, "), .citation(page: 3, label: "[3]")])
        XCTAssertEqual(AICitation.parts(in: "[S. 98, 99]", pages: pages(3)), [.text("[S. 98, 99]")])
        XCTAssertEqual(AICitation.markdown("[S. 1, 3]", pages: pages(3)), "[S. 1](noty-ai://page/1), [3](noty-ai://page/3)")
    }

    func testCitationLinksKeepInlineFormatting() throws {
        let markdown = AICitation.markdown("**Satz [S. 2] weiter** und [S. 9]", pages: pages(3))
        XCTAssertEqual(markdown, "**Satz [S. 2](noty-ai://page/2) weiter** und [S. 9]")
        XCTAssertEqual(AICitation.page(from: try XCTUnwrap(URL(string: "noty-ai://page/2"))), 2)
        for other in ["noty-ai://page/x", "noty-ai://andere/2", "https://page/2", "noty-ai://page/0"] {
            XCTAssertNil(AICitation.page(from: try XCTUnwrap(URL(string: other))), other)
        }
    }

    func testNoLinkInCodeOrAfterABackslash() {
        let all = pages(9)
        for text in ["`[S. 1]`", "Code `a [S. 1] b` Ende", "``x ` [S. 1]``", "\\[S. 1]", "`[S. 1, 2]`"] {
            XCTAssertEqual(AICitation.markdown(text, pages: all), text, text)
        }
        XCTAssertEqual(AICitation.markdown("`a` [S. 2] `[S. 3]`", pages: all), "`a` [S. 2](noty-ai://page/2) `[S. 3]`")
        XCTAssertEqual(AICitation.markdown("` offen [S. 2]", pages: all), "` offen [S. 2](noty-ai://page/2)", "Ein Backtick allein ist kein Code")
        XCTAssertEqual(AICitation.markdown("``ungleich` [S. 2]", pages: all), "``ungleich` [S. 2](noty-ai://page/2)")
        XCTAssertEqual(AICitation.markdown("\\\\[S. 2]", pages: all), "\\\\[S. 2](noty-ai://page/2)", "Doppelter Backslash ist selbst das Escape")
        XCTAssertEqual(AICitation.markdown("\\`[S. 2]\\`", pages: all), "\\`[S. 2](noty-ai://page/2)\\`", "Maskierter Backtick öffnet keinen Code")
        XCTAssertEqual(AICitation.markdown("Ende\\", pages: all), "Ende\\")
    }

    // MARK: Consent

    func testConsentBelongsToServerAndAccount() throws {
        let server = try XCTUnwrap(AIServerAddress.parse("https://a.ts.net:8443"))
        let other = try XCTUnwrap(AIServerAddress.parse("https://b.ts.net:8443"))
        let otherPort = try XCTUnwrap(AIServerAddress.parse("https://a.ts.net:9443"))
        let key = try XCTUnwrap(AIConsent.key(server: server, account: "u1"))
        XCTAssertEqual(AIConsent.key(server: server, account: "u1"), key)
        XCTAssertNotEqual(AIConsent.key(server: other, account: "u1"), key)
        XCTAssertNotEqual(AIConsent.key(server: otherPort, account: "u1"), key)
        XCTAssertNotEqual(AIConsent.key(server: server, account: "u2"), key)
        XCTAssertNil(AIConsent.key(server: server, account: ""))
        XCTAssertNotEqual(AIConsent.key(server: server, account: "a|b"), AIConsent.key(server: server, account: "a%7Cb"))
        XCTAssertEqual(AIServerAddress.authority(of: server), "a.ts.net:8443")
        XCTAssertEqual(AIServerAddress.authority(of: try XCTUnwrap(AIServerAddress.parse("https://a.ts.net"))), "a.ts.net")
    }

    func testOldApprovalsPerNotebookCountForNothing() throws {
        let server = try XCTUnwrap(AIServerAddress.parse("https://a.ts.net"))
        let key = try XCTUnwrap(AIConsent.key(server: server, account: "u1"))
        let document = UUID()
        XCTAssertEqual(AIConsent.valid([document.uuidString, "v2|a.ts.net|u1|\(document.uuidString)", key, "c1|a.ts.net|u1|x"]), [key])
    }

    // MARK: Repeating a delivery

    func testFingerprintCoversEverythingThatGoesOut() {
        let image = AITurnImage(mimeType: "image/jpeg", base64: "AAAA", label: "Seite 1")
        let base = AITurnRequest(requestId: "abcdefgh-1", text: "Frage", context: AITurnContext(label: "Mathe", text: "Inhalt"), images: [image])
        var other = base; other.requestId = "abcdefgh-2"
        XCTAssertEqual(base.contentFingerprint, other.contentFingerprint, "Die Kennung gehört nicht zum Inhalt")
        var changes: [AITurnRequest] = []
        var change = base; change.text = "Frage?"; changes.append(change)
        change = base; change.context?.text = "Inhalt gelöscht"; changes.append(change)
        change = base; change.context?.label = "Deutsch"; changes.append(change)
        change = base; change.context = nil; changes.append(change)
        change = base; change.images = nil; changes.append(change)
        change = base; change.images?[0].base64 = "BBBB"; changes.append(change)
        change = base; change.images?[0].label = "Seite 2"; changes.append(change)
        change = base; change.model = "m"; changes.append(change)
        for changed in changes { XCTAssertNotEqual(changed.contentFingerprint, base.contentFingerprint) }
        var moved = base; moved.context = AITurnContext(label: "MathI", text: "nhalt")
        XCTAssertNotEqual(moved.contentFingerprint, base.contentFingerprint, "Feldgrenzen zählen mit")
    }

    func testRepeatKeepsTheRequestIDOnlyForIdenticalContent() {
        let first = AIPendingDelivery.resolve(fingerprint: "a", previous: nil)
        XCTAssertTrue(AITurnRequest.isValidRequestID(first.requestID))
        XCTAssertEqual(AIPendingDelivery.resolve(fingerprint: "a", previous: first), first)
        XCTAssertNotEqual(AIPendingDelivery.resolve(fingerprint: "b", previous: first).requestID, first.requestID)
        XCTAssertNotEqual(AIPendingDelivery.resolve(fingerprint: "a", previous: nil).requestID, first.requestID)
    }

    // MARK: Requests

    func testCancelledRequestsAreNoFailure() {
        XCTAssertTrue(AIRequestFailure.isCancellation(CancellationError()))
        XCTAssertTrue(AIRequestFailure.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(AIRequestFailure.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(AIRequestFailure.isCancellation(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: ""))))
    }

    private func session(_ id: String = "s", revision: Int, messages: [AIMessage] = []) -> AISession {
        AISession(id: id, documentId: nil, title: nil, status: .idle, revision: revision, updatedAt: 0, messages: messages)
    }

    func testOnlyANewerRevisionReplacesAChat() {
        XCTAssertTrue(session(revision: 3).supersedes(nil))
        XCTAssertTrue(session(revision: 3).supersedes(session(revision: 2)))
        XCTAssertFalse(session(revision: 3).supersedes(session(revision: 3)))
        XCTAssertFalse(session(revision: 3).supersedes(session(revision: 4)))
        XCTAssertTrue(session("t", revision: 1).supersedes(session(revision: 4)), "Ein anderer Chat ist kein älterer Stand")
    }

    func testAnswerBelongsToTheQuestionBeforeIt() {
        let chat = session(revision: 1, messages: [
            AIMessage(id: "lose", role: .assistant, text: "ohne Frage"),
            AIMessage(id: "r1", role: .user, text: "Eins"),
            AIMessage(id: "a1", role: .assistant, text: "A"),
            AIMessage(id: "n", role: .system, text: "Hinweis"),
            AIMessage(id: "a2", role: .assistant, text: "B"),
            AIMessage(id: "r2", role: .user, text: "Zwei"),
            AIMessage(id: "a3", role: .assistant, text: "C"),
        ])
        XCTAssertEqual(chat.answerRequests, ["a1": "r1", "a2": "r1", "a3": "r2"])
    }

    func testContextNamesItsPagesByStableID() {
        let first = input(1, "Eins"), empty = AIContextPage(number: 2, pageID: UUID()), third = input(3, "Drei")
        XCTAssertEqual(AIContextBuilder.build([first, empty, third]).includedPageIDs, [1: first.pageID, 3: third.pageID])
        let long = String(repeating: "x", count: 1_000)
        let cut = (1...4).map { input($0, long) }
        let context = AIContextBuilder.build(cut, limit: 2_000)
        XCTAssertEqual(context.truncatedPage, 2)
        XCTAssertEqual(Set(context.includedPageIDs.keys), Set(context.includedPages), "Abgeschnittene Seite ist Kontext, fehlende nicht")
    }

    // MARK: Reading one page

    func testSinglePageReadMatchesTheWholeNotebook() {
        var book = notebook([page("Eins"), page("Zwei"), page("Drei")])
        book.pages[1].drawing = Data([1, 2, 3])
        let prepared = ContentSearchPlanner.prepare(book)
        var index = ContentSearchPlanner.reconcile(nil, documentID: book.id, pages: prepared)
        index.pages[1].handwriting = SearchLayerRecord(fingerprint: prepared[1].fingerprints.handwriting!, lines: [line("erkannt", .handwriting)])
        XCTAssertEqual(AIContextBuilder.pages(of: book, index: index, only: book.pages[1].id), [AIContextBuilder.pages(of: book, index: index)[1]])
        XCTAssertEqual(AIContextBuilder.pages(of: book, index: index, only: UUID()), [])
    }

    func testSinglePageReadMatchesForPDFSources() throws {
        var book = notebook([page("Eins"), page("Zwei")])
        let source = PDFSource(id: UUID(), data: Data(repeating: 7, count: 4_000), pageCount: 2)
        let foreign = PDFSource(id: UUID(), data: Data(repeating: 8, count: 4_000), pageCount: 1)
        book.pdfSources = [source, foreign]
        book.pages[1].pdfReference = PDFPageReference(sourceID: source.id, pageIndex: 1)
        let prepared = ContentSearchPlanner.prepare(book)
        var index = ContentSearchPlanner.reconcile(nil, documentID: book.id, pages: prepared)
        let fingerprint = try XCTUnwrap(prepared[1].fingerprints.pdfText)
        index.pages[1].pdfText = SearchLayerRecord(fingerprint: fingerprint, lines: [line("PDF", .pdf)])
        let single = AIContextBuilder.pages(of: book, index: index, only: book.pages[1].id)
        XCTAssertEqual(single.first?.pdfText.map(\.text), ["PDF"], "Gleicher Fingerabdruck wie beim ganzen Heft")
        XCTAssertEqual(single, [AIContextBuilder.pages(of: book, index: index)[1]])
    }

    func testCancelledReadStops() async {
        let book = notebook((0..<50).map { _ in page("Text") })
        let task = Task.detached { () -> Int in
            while !Task.isCancelled { await Task.yield() }
            return AIContextBuilder.pages(of: book, index: nil).count
        }
        task.cancel()
        let count = await task.value
        XCTAssertEqual(count, 0)
    }

    func testIndexIsDecodedOnlyWhenTheFileChanged() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ContentSearchIndexStore(directory: directory)
        let id = UUID(), file = directory.appendingPathComponent(id.uuidString + ".json")
        let empty = await store.loadRemembered(id)
        XCTAssertNil(empty)
        await store.save(SearchDocumentIndex(documentID: id))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let first = await store.loadRemembered(id)
        XCTAssertNotNil(first)

        // Same date and size, unreadable content: a decoder would fail here.
        let size = try Data(contentsOf: file).count
        try Data(repeating: 0x20, count: size).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        let again = await store.loadRemembered(id)
        XCTAssertEqual(again, first)

        await store.save(SearchDocumentIndex(documentID: id, revisionStamp: "neu"))
        let changed = await store.loadRemembered(id)
        XCTAssertEqual(changed?.revisionStamp, "neu")
        await store.remove([id])
        let gone = await store.loadRemembered(id)
        XCTAssertNil(gone)
    }

    // MARK: PDF text at the limit

    func testBudgetEndsAtTheLimit() {
        var budget = AIContextBudget(limit: 10)
        XCTAssertFalse(budget.exhausted)
        budget.add(input(1, "123456789"))
        XCTAssertFalse(budget.exhausted)
        var page = input(2, "1")
        page.handwriting = [line("2", .handwriting)]
        XCTAssertEqual(page.knownLength, 2)
        budget.add(page)
        XCTAssertTrue(budget.exhausted)
    }

    func testPagesSkippedAtTheLimitCountAsOmitted() {
        var skipped = AIContextPage(number: 2, pageID: UUID(), missing: [.pdfText])
        skipped.skipAtLimit()
        XCTAssertFalse(skipped.missing.contains(.pdfText))
        XCTAssertFalse(skipped.needsRecognition, "Ungelesen ist nicht unerkannt")
        let context = AIContextBuilder.build([input(1, "Eins"), skipped, input(3, "Drei")])
        XCTAssertEqual(context.includedPages, [1])
        XCTAssertEqual(context.omittedPages, [2, 3], "Dahinter wird nichts nachgeholt")
        XCTAssertEqual(context.unrecognizedPages, [])
        XCTAssertTrue(context.wasTruncated)
    }

    func testPDFTextIsRememberedPerSourceAndPage() {
        var cache = AIPDFTextCache(capacity: 10)
        let document = UUID(), source = UUID()
        var first = Page(); first.pdfReference = PDFPageReference(sourceID: source, pageIndex: 0)
        var duplicate = Page(); duplicate.pdfReference = first.pdfReference
        var second = Page(); second.pdfReference = PDFPageReference(sourceID: source, pageIndex: 1)
        XCTAssertEqual(AIPDFTextCache.key(page: first, document: document), AIPDFTextCache.key(page: duplicate, document: UUID()))
        XCTAssertNotEqual(AIPDFTextCache.key(page: first, document: document), AIPDFTextCache.key(page: second, document: document))
        let legacy = Page(), other = Page()
        XCTAssertNotEqual(AIPDFTextCache.key(page: legacy, document: document), AIPDFTextCache.key(page: other, document: document))
        XCTAssertNotEqual(AIPDFTextCache.key(page: legacy, document: document), AIPDFTextCache.key(page: legacy, document: UUID()))

        cache.remember("", for: "scan")
        XCTAssertEqual(cache.text(for: "scan"), "", "Auch ein Scan ohne Text wird nicht neu gelesen")
        cache.remember("12345", for: "a")
        cache.remember("123456", for: "b")
        XCTAssertNil(cache.text(for: "a"), "Über der Grenze beginnt der Speicher neu")
        XCTAssertEqual(cache.text(for: "b"), "123456")
        cache.remember(String(repeating: "x", count: 11), for: "c")
        XCTAssertNil(cache.text(for: "c"))
        XCTAssertEqual(cache.text(for: "b"), "123456")
    }
}

final class AIPanelSupportTests: XCTestCase {
    // MARK: Citation ledger

    func testLedgerNamesThePagesOfARequest() throws {
        var ledger = AICitationLedger()
        let document = UUID(), page = UUID()
        ledger.record(requestID: "r1", document: document, pages: [3: page])
        XCTAssertEqual(ledger.pages(requestID: "r1", document: document), [3: page])
        XCTAssertEqual(ledger.pages(requestID: "r1", document: UUID()), [:], "Fremdes Heft")
        XCTAssertEqual(ledger.pages(requestID: "r2", document: document), [:], "Unbekannte Anfrage")

        let saved = try JSONEncoder().encode(ledger)
        XCTAssertEqual(try JSONDecoder().decode(AICitationLedger.self, from: saved), ledger)
    }

    func testLedgerDropsTheOldestEntries() {
        var ledger = AICitationLedger(capacity: 2)
        let document = UUID(), page = UUID()
        ledger.record(requestID: "r1", document: document, pages: [1: page])
        ledger.record(requestID: "r2", document: document, pages: [1: page])
        ledger.record(requestID: "r1", document: document, pages: [2: page])
        ledger.record(requestID: "r3", document: document, pages: [1: page])
        XCTAssertEqual(ledger.pages(requestID: "r2", document: document), [:], "Wiederholte Anfrage zählt als neu")
        XCTAssertEqual(ledger.pages(requestID: "r1", document: document), [2: page])
        XCTAssertEqual(ledger.pages(requestID: "r3", document: document), [1: page])
        ledger.record(requestID: "r3", document: document, pages: [:])
        XCTAssertEqual(ledger.pages(requestID: "r3", document: document), [:])
    }

    // MARK: Presence

    func testPanelStaysVisibleWhenTheNewOneAppearsFirst() {
        var presence = AIPanelPresence()
        XCTAssertFalse(presence.visible)
        presence.appeared(); presence.appeared(); presence.disappeared()
        XCTAssertTrue(presence.visible)
        presence.disappeared()
        XCTAssertFalse(presence.visible)
        presence.disappeared()
        presence.appeared()
        XCTAssertTrue(presence.visible, "Überzähliges Verschwinden zählt nicht")
    }

    // MARK: Placement

    private let landscape = PageRect(x: 0, y: 0, width: 1180, height: 820)
    private let portrait = PageRect(x: 0, y: 0, width: 820, height: 1180)
    private let leftPane = PageRect(x: 0, y: 0, width: 587, height: 820)
    private let rightPane = PageRect(x: 593, y: 0, width: 587, height: 820)
    private let topPane = PageRect(x: 0, y: 0, width: 820, height: 587)
    private let bottomPane = PageRect(x: 0, y: 593, width: 820, height: 587)

    private func overlaps(_ a: PageRect, _ b: PageRect) -> Bool {
        a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
    }
    private func contains(_ outer: PageRect, _ inner: PageRect) -> Bool {
        inner.x >= outer.x && inner.y >= outer.y && inner.x + inner.width <= outer.x + outer.width && inner.y + inner.height <= outer.y + outer.height
    }

    func testPanelLiesOverTheInactiveView() {
        let right = AIPanelPlacement.frame(area: landscape, active: leftPane, inactive: rightPane, law: nil, flipped: false)
        XCTAssertFalse(overlaps(right, leftPane))
        XCTAssertEqual(right.width, AIPanelPlacement.width)
        XCTAssertEqual(right.x, 1180 - 10 - 380)
        let left = AIPanelPlacement.frame(area: landscape, active: rightPane, inactive: leftPane, law: nil, flipped: false)
        XCTAssertFalse(overlaps(left, rightPane))
        XCTAssertEqual(left.x, 10)
    }

    func testGripSwitchesTheSide() {
        let flipped = AIPanelPlacement.frame(area: landscape, active: leftPane, inactive: rightPane, law: nil, flipped: true)
        XCTAssertFalse(overlaps(flipped, rightPane))
        let single = AIPanelPlacement.frame(area: landscape, active: nil, inactive: nil, law: nil, flipped: false)
        XCTAssertEqual(single.x, 1180 - 10 - 380)
        XCTAssertEqual(AIPanelPlacement.frame(area: landscape, active: nil, inactive: nil, law: nil, flipped: true).x, 10)
    }

    func testStackedViewsGetABroadPanelInPortrait() {
        let lower = AIPanelPlacement.frame(area: portrait, active: topPane, inactive: bottomPane, law: nil, flipped: false)
        XCTAssertFalse(overlaps(lower, topPane))
        XCTAssertEqual(lower.width, AIPanelPlacement.stackedWidth)
        let upper = AIPanelPlacement.frame(area: portrait, active: bottomPane, inactive: topPane, law: nil, flipped: false)
        XCTAssertFalse(overlaps(upper, bottomPane))
    }

    func testPortraitSideBySideStaysInsideTheView() {
        let area = PageRect(x: 0, y: 0, width: 820, height: 1180)
        let first = PageRect(x: 0, y: 0, width: 407, height: 1180), second = PageRect(x: 413, y: 0, width: 407, height: 1180)
        let frame = AIPanelPlacement.frame(area: area, active: first, inactive: second, law: nil, flipped: false)
        XCTAssertFalse(overlaps(frame, first))
        XCTAssertGreaterThanOrEqual(frame.width, AIPanelPlacement.minimumWidth)
    }

    func testPanelNeverLeavesTheAreaOnSmallRooms() {
        let small = PageRect(x: 40, y: 20, width: 320, height: 200)
        let frame = AIPanelPlacement.frame(area: small, active: nil, inactive: nil, law: nil, flipped: false)
        XCTAssertTrue(contains(small, frame))
    }

    func testPanelAvoidsAFloatingLawWindow() {
        // Right side window of the same size, active view on the left.
        let law = PageRect(x: 790, y: 10, width: 380, height: 800)
        let frame = AIPanelPlacement.frame(area: landscape, active: leftPane, inactive: rightPane, law: law, flipped: false)
        XCTAssertFalse(overlaps(frame, law))
        XCTAssertEqual(frame.width, AIPanelPlacement.minimumWidth, "So wenig wie möglich von der aktiven Ansicht verdecken")
        XCTAssertEqual(frame.x + frame.width, law.x - AIPanelPlacement.gap)

        let other = PageRect(x: 10, y: 10, width: 380, height: 800)
        XCTAssertEqual(AIPanelPlacement.frame(area: landscape, active: leftPane, inactive: rightPane, law: other, flipped: false).width,
                       AIPanelPlacement.width, "Gesetzesfenster auf der anderen Seite stört nicht")
    }

    func testPanelStaysAboveABottomLawWindow() {
        let law = PageRect(x: 10, y: 450, width: 1160, height: 360)
        let frame = AIPanelPlacement.frame(area: landscape, active: leftPane, inactive: rightPane, law: law, flipped: false)
        XCTAssertFalse(overlaps(frame, law))
        XCTAssertFalse(overlaps(frame, leftPane))
        XCTAssertGreaterThanOrEqual(frame.height, AIPanelPlacement.minimumHeight)
    }

    func testStashedLawTabStaysReachable() {
        let layout = LawPanelLayout(size: PageSize(width: 1180, height: 820), width: 380, height: 360, docked: false, edge: .right)
        let strip = layout.edgeStrip(depth: 48)
        let frame = AIPanelPlacement.frame(area: landscape, active: leftPane, inactive: rightPane, law: strip, flipped: false)
        XCTAssertFalse(overlaps(frame, strip))
        XCTAssertFalse(overlaps(frame, leftPane))
        XCTAssertEqual(LawPanelLayout(size: PageSize(width: 100, height: 80), width: 380, height: 360, docked: false, edge: .bottom).edgeStrip(depth: 48),
                       PageRect(x: 0, y: 32, width: 100, height: 48))
        XCTAssertEqual(LawPanelLayout(size: PageSize(width: 100, height: 80), width: 380, height: 360, docked: false, edge: .left).edgeStrip(depth: 48),
                       PageRect(x: 0, y: 0, width: 48, height: 80))
    }

    func testLawGripStaysFreeWithoutRoomBeside() {
        let narrow = PageRect(x: 0, y: 0, width: 500, height: 700)
        let law = PageRect(x: 110, y: 10, width: 380, height: 680)
        let frame = AIPanelPlacement.frame(area: narrow, active: nil, inactive: nil, law: law, flipped: false)
        let grip = PageRect(x: law.x, y: law.y, width: law.width, height: AIPanelPlacement.lawGrip)
        XCTAssertFalse(overlaps(frame, grip))
        XCTAssertGreaterThan(frame.height, AIPanelPlacement.minimumHeight)
    }
}
