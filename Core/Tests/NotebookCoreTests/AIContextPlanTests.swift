import Foundation
import XCTest
@testable import NotebookCore

final class AIContextPlanTests: XCTestCase {
    private func line(_ text: String, _ kind: SearchContentKind) -> SearchLine {
        SearchLine(text: text, kind: kind, bounds: PageRect(x: 0, y: 0, width: 10, height: 10))
    }
    private func typed(_ number: Int, _ text: String) -> AIContextPage {
        AIContextPage(number: number, pageID: UUID(), text: [line(text, .text)])
    }
    /// A notebook far above the compact budget: 30 pages of 2 000 characters.
    private func bigNotebook() -> [AIContextPage] {
        (1...30).map { number in
            let topic = number == 17 ? "Die Stichtagsinventur findet am Bilanzstichtag statt. " : "Allgemeiner Stoff über Buchführung. "
            return typed(number, "Kapitel \(number)\n" + String(repeating: topic, count: 2_000 / topic.count))
        }
    }

    // MARK: Modes

    func testModesSendOnlyTheirEffort() {
        XCTAssertEqual(AIAnswerMode.allCases.map(\.effort), ["low", "medium", "high"])
        XCTAssertEqual(AIAnswerMode(stored: nil), .fast)
        XCTAssertEqual(AIAnswerMode(stored: "unbekannt"), .fast)
        XCTAssertEqual(AIAnswerMode(stored: "thinking"), .thinking)
        XCTAssertTrue(AIAnswerMode.thinking.showsThinking)
        XCTAssertFalse(AIAnswerMode.balanced.showsThinking)
        XCTAssertEqual(Set(AIAnswerMode.allCases.map(\.title)).count, 3)
    }

    func testModeIsPartOfTheFingerprint() {
        let base = AITurnRequest(requestId: "abcdefgh-1", text: "Frage", effort: AIAnswerMode.fast.effort)
        var other = base; other.effort = AIAnswerMode.thinking.effort
        XCTAssertNotEqual(base.contentFingerprint, other.contentFingerprint, "Ein Moduswechsel ist keine identische Wiederholung")
        let first = AIPendingDelivery.resolve(fingerprint: base.contentFingerprint, previous: nil)
        XCTAssertNotEqual(AIPendingDelivery.resolve(fingerprint: other.contentFingerprint, previous: first).requestID, first.requestID)
        XCTAssertNil(base.model, "Das Standardmodell des Kontos gilt")
    }

    // MARK: Exclusions

    func testExclusionsAreKeptByDocumentID() {
        let a = UUID(), b = UUID()
        var exclusions = AIDocumentExclusions(stored: [a.uuidString, "kaputt"])
        XCTAssertTrue(exclusions.contains(a))
        XCTAssertFalse(exclusions.contains(b))
        exclusions.set(b, excluded: true); exclusions.set(a, excluded: false)
        XCTAssertEqual(AIDocumentExclusions(stored: exclusions.stored), exclusions)
        XCTAssertEqual(exclusions.stored, [b.uuidString])
    }

    // MARK: Budget and selection

    func testSmallNotebookGoesAlongWhole() {
        let pages = [typed(1, "Eins"), typed(2, "Zwei"), typed(3, "Drei")]
        let plan = AIContextPlan.make(pages, request: AIContextRequest(scope: .notebook, current: 2, question: "Was steht hier?"))
        XCTAssertFalse(plan.context.selected)
        XCTAssertEqual(plan.context.includedPages, [1, 2, 3])
        XCTAssertTrue(plan.context.text.hasPrefix("--- Seite 1 ---\nEins\n\n--- Seite 2 ---\nZwei"))
        XCTAssertTrue(plan.context.text.hasSuffix("[noty: Geöffnet ist Seite 2.]"), "Wechselndes steht am Ende")
        XCTAssertEqual(AIContextSummary.detail(scope: .notebook, plan: plan, hasQuestion: true), "3 Seiten")
    }

    func testStableTextAcrossQuestionsAndOpenPages() {
        let pages = [typed(1, "Eins"), typed(2, "Zwei")]
        let a = AIContextPlan.make(pages, request: AIContextRequest(scope: .notebook, current: 1, question: "A"))
        let b = AIContextPlan.make(pages, request: AIContextRequest(scope: .notebook, current: 2, question: "Ganz andere Frage"))
        let prefix = "--- Seite 1 ---\nEins\n\n--- Seite 2 ---\nZwei"
        XCTAssertTrue(a.context.text.hasPrefix(prefix) && b.context.text.hasPrefix(prefix), "Gleicher Anfang für den Prompt-Cache")
    }

    func testLargeNotebookIsSelectedByRelevanceAndNeighbourhood() {
        let pages = bigNotebook()
        let request = AIContextRequest(scope: .notebook, current: 3, question: "Wann findet die Stichtagsinventur statt?")
        let plan = AIContextPlan.make(pages, request: request)
        let context = plan.context
        XCTAssertTrue(context.selected)
        XCTAssertLessThanOrEqual(context.text.utf16.count, AIContextSize.compact)
        XCTAssertTrue(context.includedPages.contains(17), "Passende Seite")
        XCTAssertTrue([2, 3, 4].allSatisfy(context.includedPages.contains), "Geöffnete Seite und Nachbarn")
        XCTAssertEqual(context.includedPages, context.includedPages.sorted(), "Seitenreihenfolge bleibt")
        XCTAssertTrue(context.text.hasPrefix("--- Gliederung ---\nS. 1: Kapitel 1\nS. 2: Kapitel 2"), "Gliederung zuerst")
        XCTAssertEqual(context.textPageCount, 30)
        XCTAssertEqual(context.includedPages.count + context.omittedPages.count, 30, "Keine Seite geht verloren")
        XCTAssertNotNil(context.citablePageIDs[25], "Seiten der Gliederung sind zitierbar")
        XCTAssertTrue(context.text.contains("[noty: Auswahl: \(context.includedPages.count) von 30 Seiten vollständig"))
        XCTAssertEqual(AIContextSummary.detail(scope: .notebook, plan: plan, hasQuestion: true),
                       "\(context.includedPages.count) von 30 Seiten passend zur Frage")
        XCTAssertTrue(AIContextSummary.label(title: "BWL", scope: .notebook, plan: plan).hasPrefix("BWL, ganzes Heft ("))
    }

    func testFollowUpQuestionUsesThePreviousOne() {
        let pages = bigNotebook()
        let plain = AIContextPlan.make(pages, request: AIContextRequest(scope: .notebook, current: 1, question: "Und warum?"))
        XCTAssertFalse(plain.context.includedPages.contains(17))
        let followUp = AIContextPlan.make(pages, request: AIContextRequest(scope: .notebook, current: 1, question: "Und warum?",
                                                                           previousQuestion: "Was ist die Stichtagsinventur?"))
        XCTAssertTrue(followUp.context.includedPages.contains(17))
    }

    func testSummaryUsesTheLargeBudget() {
        XCTAssertTrue(AIContextSize.wantsWholeNotebook("Fasse das Heft zusammen"))
        XCTAssertTrue(AIContextSize.wantsWholeNotebook("Gib mir einen Überblick"))
        XCTAssertFalse(AIContextSize.wantsWholeNotebook("Was ist eine Inventur?"))
        let pages = bigNotebook()
        let plan = AIContextPlan.make(pages, request: AIContextRequest(scope: .notebook, current: 1, question: "Bitte zusammenfassen"))
        XCTAssertFalse(plan.context.selected, "60 000 Zeichen passen ins große Budget")
        XCTAssertEqual(plan.context.includedPages.count, 30)
        let suggestion = AIContextRequest(scope: .notebook, current: 1, question: "Hallo", wholeNotebook: true)
        XCTAssertEqual(suggestion.budget, AILimits.contract.maxContextChars)
    }

    func testSelectionNeverExceedsTheLimit() {
        let pages = (1...200).map { typed($0, String(repeating: "Wort \($0) ", count: 300)) }
        for budget in [1_000, 5_000, 40_000, 200_000] {
            let context = AIContextBuilder.build(pages, limit: 200_000, budget: budget, focus: 100, query: ["Wort 150"], fill: budget > 40_000)
            XCTAssertLessThanOrEqual(context.text.utf16.count, budget, "Budget \(budget)")
            XCTAssertEqual(context.includedPages.count + context.omittedPages.count, 200)
        }
    }

    func testHugeOpenPageIsCutHonestly() {
        let pages = [typed(1, "Eins"), typed(2, String(repeating: "x", count: 50_000)), typed(3, "Drei")]
        let context = AIContextBuilder.build(pages, limit: 200_000, budget: 40_000, focus: 2)
        XCTAssertTrue(context.selected)
        XCTAssertEqual(context.truncatedPage, 2)
        XCTAssertTrue(context.truncationNotice?.contains("Seite 2 nur teilweise") ?? false)
        XCTAssertLessThanOrEqual(context.text.utf16.count, 40_000)
    }

    // MARK: Images

    func testNotebookImagesOnlyForPagesWithoutUsableText() {
        var scan = AIContextPage(number: 2, pageID: UUID(), missing: [.imageOCR], hasPDF: true)
        scan.fillPDFText("")
        var drawing = AIContextPage(number: 3, pageID: UUID(), hasInk: true)
        drawing.handwriting = []
        var written = AIContextPage(number: 4, pageID: UUID(), hasInk: true)
        written.handwriting = [line("Eine lange erkannte Handschrift mit genug Buchstaben", .handwriting)]
        let unread = AIContextPage(number: 6, pageID: UUID(), missing: [.handwriting], hasInk: true)
        let pages = [typed(1, "Text"), scan, drawing, written, typed(5, "Text"), unread]
        XCTAssertTrue(scan.wantsImage)
        XCTAssertTrue(drawing.wantsImage, "Zeichnung ohne erkannten Text")
        XCTAssertFalse(written.wantsImage, "Erkannte Handschrift genügt als Text")
        let plan = AIContextPlan.make(pages, request: AIContextRequest(scope: .notebook, current: 3, question: "Frage"))
        XCTAssertEqual(plan.imagePages, [3, 2, 6], "Geöffnete Seite zuerst, dann nach Abstand")
        XCTAssertEqual(Set(plan.imagePageIDs.keys), [2, 3, 6])
        XCTAssertEqual(plan.citablePages[6], unread.pageID)
        XCTAssertTrue(plan.context.text.contains("Als Bild beigefügt: Seiten 2–3, 6."))
        XCTAssertFalse(plan.context.text.contains("Noch nicht erkannt"), "Was als Bild mitgeht, fehlt nicht")
    }

    func testAtMostFourImagesNearTheOpenPage() {
        let pages = (1...10).map { AIContextPage(number: $0, pageID: UUID(), missing: [.handwriting], hasInk: true) }
        XCTAssertEqual(AIContextPlan.imagePages(pages, scope: .notebook, current: 5, maxImages: 10), [5, 6, 4, 7])
        XCTAssertEqual(AIContextPlan.imagePages(pages, scope: .notebook, current: 1, maxImages: 2), [1, 2])
        XCTAssertEqual(AIContextPlan.imagePages(pages, scope: .notebook, current: 1, maxImages: 0), [])
    }

    func testPageScopeAlwaysSendsTheWholePageWhenAnythingIsOnIt() {
        var text = typed(2, "Ausführlich getippter Text mit sehr vielen Buchstaben darin")
        text.hasPDF = true
        let plan = AIContextPlan.make([text], request: AIContextRequest(scope: .page, current: 2, question: "Frage"))
        XCTAssertEqual(plan.imagePages, [2], "Auch mit brauchbarem Text: Bild der ganzen Seite")
        XCTAssertEqual(plan.context.includedPages, [2])
        XCTAssertFalse(plan.context.text.contains("Geöffnet ist"), "Bei einer Seite überflüssig")
        XCTAssertEqual(AIContextSummary.detail(scope: .page, plan: plan, hasQuestion: false), "Text und Bild")
        XCTAssertEqual(AIContextSummary.label(title: "BWL", scope: .page, plan: plan), "BWL, Seite 2")

        let shapes = AIContextPage(number: 1, pageID: UUID(), hasShapes: true)
        XCTAssertEqual(AIContextPlan.imagePages([shapes], scope: .page, current: 1, maxImages: 4), [1])
        let empty = AIContextPage(number: 1, pageID: UUID())
        XCTAssertEqual(AIContextPlan.imagePages([empty], scope: .page, current: 1, maxImages: 4), [], "Leere Seite: kein Bild")
        let emptyPlan = AIContextPlan.make([empty], request: AIContextRequest(scope: .page, current: 1, question: "Frage"))
        XCTAssertEqual(AIContextSummary.detail(scope: .page, plan: emptyPlan, hasQuestion: false), "leere Seite")
    }

    func testScanOnlyNotebookStillTellsTheModelWhatItSees() {
        var scan = AIContextPage(number: 1, pageID: UUID(), missing: [.imageOCR], hasPDF: true)
        scan.fillPDFText("")
        let plan = AIContextPlan.make([scan], request: AIContextRequest(scope: .notebook, current: 1, question: "Frage"))
        XCTAssertFalse(plan.context.hasPageText)
        XCTAssertEqual(plan.context.text, "[noty: Als Bild beigefügt: Seite 1.]")
        XCTAssertEqual(AIContextSummary.detail(scope: .notebook, plan: plan, hasQuestion: false), "Seite 1 als Bild")
    }

    // MARK: Ranking

    func testRankingFoldsCaseUmlautsAndEndings() {
        XCTAssertEqual(AITextRanking.tokens("Die Übungen zur Größe"), ["ubung", "gross"])
        let scores = AITextRanking.scores(query: "Übung Größe", documents: ["Hier stehen UEBUNGEN", "Zwei Übungen zur Grösse", "Nichts davon", ""])
        XCTAssertEqual(scores[2], 0); XCTAssertEqual(scores[3], 0)
        XCTAssertGreaterThan(scores[1], scores[0])
        XCTAssertEqual(AITextRanking.scores(query: "der die das", documents: ["der die das"]), [0], "Nur Stoppwörter")
    }

    // MARK: Suggestions and progress

    func testSuggestions() {
        XCTAssertEqual(AIPromptSuggestion.all.map(\.title), ["Erkläre diese Seite", "Fasse das Heft zusammen", "Stell mir Prüfungsfragen", "Löse Aufgabe …"])
        XCTAssertEqual(AIPromptSuggestion.all.filter(\.sendsDirectly).count, 3)
        XCTAssertEqual(AIPromptSuggestion.all.first { $0.id == "explain" }?.scope, .page)
        XCTAssertTrue(AIPromptSuggestion.all.first { $0.id == "summary" }?.wholeNotebook ?? false)
        XCTAssertEqual(AIReadingProgress(done: 1, total: 3).label, "Heft wird gelesen … 2/3")
        XCTAssertEqual(AIReadingProgress(done: 3, total: 3).label, "Heft wird gelesen … 3/3")
    }

    func testUsageIsOptionalAndNeverMadeUp() throws {
        let plain = try JSONDecoder().decode(AIMessage.self, from: Data(#"{"id":"a","role":"assistant","text":"x"}"#.utf8))
        XCTAssertNil(plain.usage)
        let counted = try JSONDecoder().decode(AIMessage.self, from: Data(#"{"id":"a","role":"assistant","text":"x","usage":{"inputTokens":12400,"cachedInputTokens":8000,"outputTokens":640}}"#.utf8))
        XCTAssertEqual(counted.usage?.summary, "12\u{202F}400 gelesen (8\u{202F}000 aus dem Cache) · 640 geschrieben")
        XCTAssertNil(AIMessageUsage().summary)
    }

    // MARK: Markdown

    func testMarkdownBlocks() {
        let text = """
        # Titel
        Ein Absatz
        mit zwei Zeilen.

        - Punkt **eins**
          - eingerückt
        2. Zweiter

        | A | Breite Spalte |
        |---|:---:|
        | **1** | zwei |

        > Zitat
        ---
        ```swift
        let x = 1
        """
        XCTAssertEqual(AIMarkdownBlocks.parse(text), [
            .heading(level: 1, text: "Titel"),
            .paragraph("Ein Absatz\nmit zwei Zeilen."),
            .listItem(indent: 0, marker: "•", text: "Punkt **eins**"),
            .listItem(indent: 1, marker: "•", text: "eingerückt"),
            .listItem(indent: 0, marker: "2.", text: "Zweiter"),
            .table([["A", "Breite Spalte"], ["**1**", "zwei"]]),
            .quote("Zitat"),
            .rule,
            .code("let x = 1"),
        ])
        XCTAssertEqual(AIMarkdownBlocks.monospaced([["A", "Breite Spalte"], ["**1**", "zwei"]]),
                       "A  Breite Spalte\n─  ─────────────\n1  zwei")
    }
}
