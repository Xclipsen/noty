import XCTest
@testable import NotebookCore

final class AIStreamingTests: XCTestCase {
    private let sample = """
    # Titel
    Ein Absatz mit **fettem Text** und einer Fundstelle [S. 3].
    Zweite Zeile des Absatzes.

    - Punkt **eins**
      - eingerückt
    2. Zweiter Punkt

    | A | Breite Spalte |
    |---|:---:|
    | **1** | zwei |

    > Zitat über
    > zwei Zeilen
    ---
    ```swift
    let x = 1

    let y = 2
    ```
    Schluss mit `Code` und Ende.
    """

    // MARK: Incremental Markdown

    func testGrowingAnswerGivesTheSameBlocksAsAFullParseAtEveryLength() {
        var stream = AIMarkdownStream<AIMarkdownBlock>()
        let characters = Array(sample)
        for length in 0...characters.count {
            let prefix = String(characters[..<length])
            let blocks = stream.update(prefix, final: false) { block, _, _ in block }
            XCTAssertEqual(blocks, AIMarkdownBlocks.parse(prefix), "Länge \(length)")
        }
        XCTAssertEqual(stream.update(sample, final: true) { block, _, _ in block }, AIMarkdownBlocks.parse(sample))
    }

    func testFinishedBlocksAreRenderedOnceAndKeepTheirIndex() {
        var stream = AIMarkdownStream<String>()
        var calls: [(Int, Bool)] = []
        func update(_ text: String, final: Bool = false) -> [String] {
            stream.update(text, final: final) { block, index, open in calls.append((index, open)); return "\(index)\(open ? "o" : "")" }
        }
        XCTAssertEqual(update("Erster Absatz.\n\nZweiter"), ["0", "1o"])
        XCTAssertEqual(calls.count, 2)
        calls = []
        XCTAssertEqual(update("Erster Absatz.\n\nZweiter Absatz wächst"), ["0", "1o"])
        XCTAssertEqual(calls.map(\.0), [1], "Nur der offene Block")
        calls = []
        XCTAssertEqual(update("Erster Absatz.\n\nZweiter Absatz wächst"), ["0", "1o"])
        XCTAssertTrue(calls.isEmpty, "Gleicher Text: nichts neu")
        XCTAssertEqual(update("Erster Absatz.\n\nZweiter Absatz wächst.\n\n- Punkt\n"), ["0", "1", "2"])
        XCTAssertEqual(calls.map(\.0), [1, 2], "Abgeschlossen: einmal endgültig, Index bleibt")
        calls = []
        XCTAssertEqual(update("Erster Absatz.\n\nZweiter Absatz wächst.\n\n- Punkt\n", final: true), ["0", "1", "2"])
        XCTAssertTrue(calls.isEmpty, "Alles war schon abgeschlossen")
        XCTAssertEqual(update("Ganz anders"), ["0o"], "Ersetzter Text beginnt neu")
    }

    func testOpenCodeBlockStaysOpenUntilItsFence() {
        var stream = AIMarkdownStream<AIMarkdownBlock>()
        var opens: [Bool] = []
        let text = "Vorher\n\n```\nlet a = 1\n\nlet b = 2\n"
        let blocks = stream.update(text, final: false) { block, _, open in opens.append(open); return block }
        XCTAssertEqual(blocks, [.paragraph("Vorher"), .code("let a = 1\n\nlet b = 2\n")])
        XCTAssertEqual(opens, [false, true], "Leerzeile im Code schließt nichts ab")
    }

    func testRenderCacheRendersFinishedAnswersOnceAndPagesAnew() {
        var cache = AIAnswerRenderCache<String>(capacity: 2)
        func blocks(_ id: String, _ text: String, pages: Set<Int> = [], final: Bool = true) -> [String] {
            cache.blocks(id: id, text: text, pages: pages, final: final) { block, index, _ in "\(index):\(block)" }
        }
        _ = blocks("a", "Eins\n\nZwei")
        _ = blocks("a", "Eins\n\nZwei")
        XCTAssertEqual(cache.renders(id: "a"), 2)
        _ = blocks("a", "Eins\n\nZwei", pages: [1])
        XCTAssertEqual(cache.renders(id: "a"), 2, "Andere Verlinkung: neu, Zähler beginnt neu")
        _ = blocks("b", "x"); _ = blocks("c", "y")
        XCTAssertEqual(cache.renders(id: "a"), 0, "Ältester Eintrag ist fort")
    }

    // MARK: Inline marks of the open block

    func testOpenInlineMarksAreClosedForDisplay() {
        XCTAssertEqual(AIMarkdownBlocks.closingOpenInline("Das ist **sehr"), "Das ist **sehr**")
        XCTAssertEqual(AIMarkdownBlocks.closingOpenInline("Das ist **fett** und `co"), "Das ist **fett** und `co`")
        XCTAssertEqual(AIMarkdownBlocks.closingOpenInline("Das ist **"), "Das ist", "Öffner ohne Inhalt fällt weg")
        XCTAssertEqual(AIMarkdownBlocks.closingOpenInline("**fett `code"), "**fett `code`**")
        XCTAssertEqual(AIMarkdownBlocks.closingOpenInline("2 ** 3 und 2 * 3"), "2 ** 3 und 2 * 3", "Rechenzeichen bleiben")
        XCTAssertEqual(AIMarkdownBlocks.closingOpenInline("`**` bleibt Code"), "`**` bleibt Code")
        XCTAssertEqual(AIMarkdownBlocks.closingOpenInline("\\**kein"), "\\**kein")
        XCTAssertEqual(AIMarkdownBlocks.closingOpenInline("__unter strich "), "__unter strich__")
    }

    // MARK: Cut points

    private func cut(_ text: String, at limit: Int, complete: Bool = false) -> String {
        let characters = Array(text)
        return String(characters[..<AIRevealCut.safeEnd(characters, upTo: limit, complete: complete)])
    }

    func testCutsAfterWholeWordsAndWholeGraphemes() {
        XCTAssertEqual(cut("Hallo Welt und mehr", at: 8), "Hallo")
        XCTAssertEqual(cut("Hallo Welt und mehr", at: 10), "Hallo Welt")
        XCTAssertEqual(cut("Hallo Welt", at: 10), "Hallo", "Letztes Wort kann noch wachsen")
        XCTAssertEqual(cut("Hallo Welt", at: 10, complete: true), "Hallo Welt")
        XCTAssertEqual(Array("Familie 👨‍👩‍👧 dabei").count, 15, "Ein Emoji aus mehreren Skalaren ist ein Zeichen")
        XCTAssertEqual(cut("Familie 👨‍👩‍👧 dabei", at: 8), "Familie", "kein halbes Emoji")
        XCTAssertEqual(cut("Familie 👨‍👩‍👧 dabei", at: 9), "Familie 👨‍👩‍👧")
        XCTAssertEqual(cut("Café über", at: 6), "Café")
    }

    func testNeverCutsInsideMarkdownMarks() {
        XCTAssertEqual(cut("Text\n## Titel kommt", at: 7), "Text\n", "## allein wäre ein Absatz")
        XCTAssertEqual(cut("Text\n## Titel kommt", at: 13), "Text\n## Titel")
        XCTAssertEqual(cut("Text\n- Punkt", at: 6), "Text\n")
        XCTAssertEqual(cut("Text\n12. Punkt", at: 9), "Text\n")
        XCTAssertEqual(cut("Text\n| A | B | C", at: 12), "Text\n", "Tabellenzeilen erst ganz")
        XCTAssertEqual(cut("Text\n| A | B |\nweiter", at: 14), "Text\n| A | B |")
        XCTAssertEqual(cut("Siehe [S. 3] dazu", at: 9), "Siehe", "Fundstelle erst ganz")
        XCTAssertEqual(cut("Siehe [S. 3] dazu", at: 12), "Siehe [S. 3]")
        XCTAssertEqual(cut("Ein [Link](https://x.de/a b) hier", at: 26), "Ein")
        XCTAssertEqual(cut("Text\n``` swift\nlet", at: 9), "Text\n")
        XCTAssertEqual(cut("Das ist **sehr fett** hier", at: 14), "Das ist **sehr", "offene Marken schließt der Renderer")
    }

    func testCutNeverGoesBelowWhatWasShown() {
        let characters = Array("Hallo Welt")
        XCTAssertEqual(AIRevealCut.safeEnd(characters, upTo: 3, complete: false, floor: 5), 5)
    }

    // MARK: Pace

    func testRevealFollowsEvenlyAndCatchesUpWithinTheLag() {
        let words = (0..<120).map { "Wort\($0)" }.joined(separator: " ") + " "
        var pacer = AIRevealPacer(text: "", at: 0)
        var time = 0.0
        var received = 0
        var shown: [Int] = []
        let characters = Array(words)
        // About 400 characters per second in chunks every 120 ms, as from the bridge.
        var nextChunk = 0.0
        while received < characters.count || pacer.backlog > 0 {
            if time >= nextChunk, received < characters.count {
                received = min(characters.count, received + 48)
                pacer.receive(String(characters[..<received]), at: time)
                nextChunk += 0.12
            }
            time += 1.0 / 60
            shown.append(pacer.advance(to: time, complete: false))
            if received == characters.count, pacer.caughtUp { break }
            XCTAssertLessThan(time, 10)
        }
        XCTAssertEqual(zip(shown, shown.dropFirst()).filter { $0 > $1 }.count, 0, "nie rückwärts")
        let steps = zip(shown, shown.dropFirst()).map { $1 - $0 }
        XCTAssertLessThanOrEqual(steps.max() ?? 0, 20, "keine groben Sprünge: höchstens etwa ein bis zwei Wörter je Bild")
        XCTAssertGreaterThan(steps.filter { $0 > 0 }.count, 60, "viele kleine Schritte")
        XCTAssertLessThan(time, Double(characters.count) / 400 + AIRevealPacer.maxLag + 0.3, "hängt nicht weit hinterher")
    }

    func testBigBacklogIsShownWithinTheMaximumLag() {
        let text = String(repeating: "wort ", count: 400)
        var pacer = AIRevealPacer(text: "a ", at: 0)
        pacer.receive(text, at: 0.05)
        var time = 0.05
        while time < 0.05 + AIRevealPacer.maxLag + 0.05 { time += 1.0 / 60; pacer.advance(to: time, complete: false) }
        XCTAssertTrue(pacer.caughtUp, "spätestens nach maxLag sichtbar")
    }

    func testLongTextOnFirstSightAndTheEndShowAtOnce() {
        let long = String(repeating: "schon da ", count: 40)
        XCTAssertEqual(AIRevealPacer(text: long, at: 0).shown, long.count - 1, "vorher Geschriebenes sofort, bis zum Wortende")
        var pacer = AIRevealPacer(text: "Kurz", at: 0)
        XCTAssertEqual(pacer.shown, 0)
        pacer.receive("Kurz und zu Ende", at: 0.01)
        XCTAssertEqual(pacer.advance(to: 0.02, complete: true), 16, "Am Ende sofort vollständig")
        XCTAssertEqual(pacer.shownText, "Kurz und zu Ende")
    }

    func testReplacedTextKeepsOnlyWhatStillMatches() {
        var pacer = AIRevealPacer(text: String(repeating: "alt ", count: 50), at: 0)
        XCTAssertGreaterThan(pacer.shown, 100)
        pacer.receive("alt alt neu", at: 1)
        XCTAssertLessThanOrEqual(pacer.shown, 8)
        XCTAssertTrue("alt alt neu".hasPrefix(pacer.shownText))
    }

    // MARK: Following

    func testScrollingUpStopsFollowingUntilTheUserIsBackAtTheBottom() {
        var follow = AIScrollFollow()
        XCTAssertTrue(follow.followsGrowth)
        follow.userScrolled(distanceFromBottom: 8)
        XCTAssertTrue(follow.followsGrowth, "kleines Zittern am Ende zählt nicht")
        follow.userScrolled(distanceFromBottom: 120)
        XCTAssertFalse(follow.followsGrowth, "hochgescrollt: Leseposition bleibt")
        XCTAssertTrue(follow.showsJumpButton(distanceFromBottom: 400))
        // Growing content alone never calls userScrolled; the state stays.
        follow.userScrolled(distanceFromBottom: 40)
        XCTAssertFalse(follow.followsGrowth, "fast unten ist nicht ganz unten")
        follow.userScrolled(distanceFromBottom: 2)
        XCTAssertTrue(follow.followsGrowth, "selbst ganz nach unten gescrollt")
        XCTAssertFalse(follow.showsJumpButton(distanceFromBottom: 300))
        follow.userScrolled(distanceFromBottom: 200)
        follow.follow()
        XCTAssertTrue(follow.followsGrowth, "Pille, eigene Frage oder anderer Chat")
    }
}

final class AILongPollTests: XCTestCase {
    func testLongPollFallsBackForOldServersAndBacksOffOnFailures() {
        var poll = AILongPoll()
        XCTAssertTrue(poll.waits)
        XCTAssertEqual(poll.delay(failures: 0), 0, "nach jeder Antwort sofort die nächste wartende Anfrage")
        poll.answered(changed: true, seconds: 0.1)
        poll.answered(changed: false, seconds: 20)
        XCTAssertTrue(poll.waits, "200 schnell und 204 nach Ablauf: der Server wartet")
        XCTAssertEqual(poll.delay(failures: 1), 1_400)
        XCTAssertEqual(poll.delay(failures: 6), 5_000)
        poll.answered(changed: false, seconds: 0.05)
        XCTAssertFalse(poll.waits, "204 sofort: alter Server, wieder alle 700 ms")
        XCTAssertEqual(poll.delay(failures: 0), 700)

        var rejected = AILongPoll()
        XCTAssertFalse(rejected.rejected(status: 404), "fehlende Sitzung bleibt ein Fehler")
        XCTAssertTrue(rejected.rejected(status: 400))
        XCTAssertFalse(rejected.waits)
        XCTAssertFalse(rejected.rejected(status: 400), "ohne wait ist 400 ein echter Fehler")
    }
}
