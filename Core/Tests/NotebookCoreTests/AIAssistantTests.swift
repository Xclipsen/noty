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

    func testCitationsSplitAnswer() {
        XCTAssertEqual(AICitation.parts(in: "Siehe [S. 3] und [S. 12].", pageCount: 12), [
            .text("Siehe "), .citation(page: 3, label: "[S. 3]"), .text(" und "), .citation(page: 12, label: "[S. 12]"), .text("."),
        ])
        XCTAssertEqual(AICitation.parts(in: "[S. 1]", pageCount: 1), [.citation(page: 1, label: "[S. 1]")])
        XCTAssertEqual(AICitation.parts(in: "", pageCount: 3), [])
    }

    func testForeignNumbersStayText() {
        for text in ["Siehe [S. 13] dort", "[S. 0]", "[S. -1]", "[S. x]", "[S. ]", "[S. 3", "[S. 99999999999999999999]", "[S. ٣]", "[s. 3]", "[S.3]"] {
            XCTAssertEqual(AICitation.parts(in: text, pageCount: 12), [.text(text)], text)
        }
        XCTAssertEqual(AICitation.parts(in: "[S. 1]", pageCount: 0), [.text("[S. 1]")])
        XCTAssertEqual(AICitation.parts(in: "[S. [S. 2]", pageCount: 3), [.text("[S. "), .citation(page: 2, label: "[S. 2]")])
    }

    func testCitationLinksKeepInlineFormatting() throws {
        let markdown = AICitation.markdown("**Satz [S. 2] weiter** und [S. 9]", pageCount: 3)
        XCTAssertEqual(markdown, "**Satz [S. 2](noty-ai://page/2) weiter** und [S. 9]")
        let url = try XCTUnwrap(URL(string: "noty-ai://page/2"))
        XCTAssertEqual(AICitation.page(from: url, pageCount: 3), 2)
        XCTAssertNil(AICitation.page(from: url, pageCount: 1), "Seite gelöscht: kein Sprung")
        for other in ["noty-ai://page/x", "noty-ai://andere/2", "https://page/2", "noty-ai://page/0"] {
            XCTAssertNil(AICitation.page(from: try XCTUnwrap(URL(string: other)), pageCount: 3), other)
        }
    }
}
