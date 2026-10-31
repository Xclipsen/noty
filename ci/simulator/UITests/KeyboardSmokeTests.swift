import XCTest

/// Do hardware keys reach the running app, and do they do what docs/KEYBOARD.md
/// says? Everything goes through `typeKey`, the path of a real key press.
/// The simulator starts without data, the test creates all it uses. Every
/// check writes one line into the attachment `tasten-*.txt`.
@MainActor
final class KeyboardSmokeTests: XCTestCase {
    private var app = XCUIApplication()
    private var lines: [String] = []

    override func setUp() async throws {
        continueAfterFailure = true
        NoIdleWait.install()
    }

    override func tearDown() async throws {
        shot("Ende")
        let report = XCTAttachment(string: lines.joined(separator: "\n") + "\n")
        report.name = "tasten-\(name.split(separator: " ").last?.dropLast() ?? "test").txt"
        report.lifetime = .keepAlways
        add(report)
        app.terminate()
    }

    // MARK: Tests

    func test1_ModeIndicatorAppearsWithFirstKey() {
        launch()
        check("Anzeige fehlt vor der ersten Taste", !indicator.exists)
        press("j")
        check("Anzeige erscheint nach der ersten Taste", waitFor(indicator))
        checkLabel("Anzeige zeigt NOR BIBLIOTHEK", indicator, contains: "NOR")
        checkLabel("Anzeige zeigt NOR BIBLIOTHEK (Kontext)", indicator, contains: "BIBLIOTHEK")
        shot("Modusanzeige")
    }

    func test2_LibraryMotions() {
        launch()
        fillLibrary(titles: ["Kurs A", "Kurs B", "Kurs C"])
        // A fresh launch: no focus yet.
        press("j")
        checkFocus("erstes j: erster Eintrag", "Kurs A")
        press("j")
        checkFocus("zweites j wirkt ebenfalls", "Kurs B")
        press("j")
        checkFocus("drittes j wirkt ebenfalls", "Kurs C")
        press("k")
        checkFocus("k: ein Eintrag zurück", "Kurs B")
        press("k")
        checkFocus("zweites k wirkt ebenfalls", "Kurs A")
        press("g")
        check("g: Which-Key erscheint", waitFor(menu))
        checkLabel("Which-Key zeigt „Gehe zu“", menu, contains: "Gehe zu")
        shot("Which-Key Bibliothek")
        press("e")
        check("Which-Key geht nach ge", waitGone(menu))
        checkFocus("ge: letzter Eintrag", "Kurs C")
        press("g"); press("g")
        checkFocus("gg: erster Eintrag", "Kurs A")
        press("g"); press(.escape)
        check("Esc schließt Which-Key", waitGone(menu))
        checkFocus("Esc nach g lässt Fokus stehen", "Kurs A")
        press("g")
        press("c", .control)
        check("⌃C schließt Which-Key", waitGone(menu))
        press("[", .control)
        press("g")
        press("g")
        checkFocus("⌃C und ⌃[ lassen die Bibliothek bedienbar", "Kurs A")
        press(.downArrow)
        checkFocus("Pfeil runter", "Kurs B")
        press(.downArrow)
        checkFocus("zweiter Pfeil runter wirkt ebenfalls", "Kurs C")
        press(.upArrow)
        checkFocus("Pfeil hoch", "Kurs B")
        shot("Bibliothek")
    }

    func test3_GridMotions() {
        launch(layout: "grid")
        fillLibrary(titles: ["Kurs A", "Kurs B", "Kurs C"])
        press("l")
        checkFocus("Raster: erstes l: erster Eintrag", "Kurs A")
        press("l")
        checkFocus("Raster: zweites l wirkt ebenfalls", "Kurs B")
        press("l")
        checkFocus("Raster: drittes l wirkt ebenfalls", "Kurs C")
        press("h")
        checkFocus("Raster: h: ein Eintrag zurück", "Kurs B")
    }

    func test4_CreateSheetByKeys() {
        launch()
        press("n", .shift)
        let sheet = app.navigationBars["Neues Textdokument"]
        check("N öffnet das Blatt „Neues Textdokument“", sheet.waitForExistence(timeout: 5))
        shot("Blatt Textdokument")
        let field = titleField
        check("Titelfeld hat sofort den Fokus", waitFor(focused: field, timeout: 2))
        press(.escape)
        if !check("Esc schließt das Blatt", waitGone(sheet)) {
            app.buttons["Abbrechen"].tap()
            _ = waitGone(sheet)
        }
        press("n", .shift)
        guard sheet.waitForExistence(timeout: 5) else { check("N öffnet das Blatt ein zweites Mal", false); return }
        if !field.holdsKeys { field.tap() }
        for letter in "enter" { press(String(letter)) }
        // Automatic capitals depend on the system; only the letters count.
        checkValue("Tasten erreichen das Titelfeld", field, "enter", ignoringCase: true)
        press(.return)
        if !check("Enter erstellt das Dokument", waitGone(sheet)) {
            app.buttons["Erstellen"].tap()
            _ = waitGone(sheet)
        }
        check("Dokument liegt in der Bibliothek", waitFor(item("Enter")))
        press("g"); press("e")
        checkFocus("Bibliothek nimmt nach dem Blatt wieder Tasten an", "Enter")
    }

    func test5_TextEditing() {
        launch()
        openNewDocument("Text")
        press("i")
        checkLabel("i: Text in INS", indicator, contains: "INS")
        shot("INS")
        guard let text = activeText() else { check("Textansicht hat den Fokus", false); return }
        write("eins", "zwei", "drei")
        checkValue("Tippen in INS kommt im Text an", text, "eins\nzwei\ndrei")
        leaveInsert()
        shot("NOR")

        press("g"); press("g")
        press("x")
        press("d")
        checkValue("x d löscht die erste Zeile", text, "zwei\ndrei")
        shot("nach x d")
        press("u")
        checkValue("u stellt sie wieder her", text, "eins\nzwei\ndrei")

        press("g"); press("g")
        press("x"); press("x")
        press("d")
        checkValue("zweimal x wählt zwei Zeilen", text, "drei")
        press("u")
        checkValue("u stellt beide Zeilen her", text, "eins\nzwei\ndrei")

        press("g"); press("g")
        press("l"); press("l")
        press("d")
        checkValue("zweimal l geht zwei Zeichen weiter", text, "ens\nzwei\ndrei")
        press("d")
        checkValue("zweites d wirkt ebenfalls", text, "ns\nzwei\ndrei")
        press("u")
        checkValue("erstes u nimmt das zweite d zurück", text, "ens\nzwei\ndrei")
        press("u")
        checkValue("zweites u wirkt ebenfalls", text, "eins\nzwei\ndrei")

        press("j"); press("j")
        press("g"); press("h")
        press("x"); press("d")
        checkValue("zweimal j geht zwei Zeilen tiefer", text, "eins\nzwei\n")
        press("u")
        press("U", .shift)
        checkValue("U wiederholt", text, "eins\nzwei\n")
    }

    func test6_EscapeLevels() {
        launch()
        openNewDocument("Ebenen")
        press("i")
        guard let text = activeText() else { check("Textansicht hat den Fokus", false); return }
        write("abc def")
        leaveInsert()

        press("g")
        check("g im Text: Which-Key erscheint", waitFor(menu))
        checkLabel("Which-Key im Text zeigt „Gehe zu“", menu, contains: "Gehe zu")
        shot("Which-Key Text")
        press(.escape)
        check("Esc schließt nur den Which-Key", waitGone(menu))
        check("Text bleibt aktiv", text.holdsKeys)

        press("g"); press("g")
        press("x")
        press(.escape)
        press("d")
        checkValue("Esc zieht die breite Auswahl auf den Cursor zusammen", text, "bc def")

        press(.escape)
        checkLabel("Letztes Esc verlässt den Text", indicator, contains: "SEITE")
        press("i")
        checkLabel("i führt von der Seite zurück in INS", indicator, contains: "INS")
        press(.escape)
        press(.escape)
        checkLabel("Wieder auf der Seite", indicator, contains: "SEITE")
        shot("Seite")
        press(.return)
        if checkLabel("Enter auf der Seite: INS", indicator, contains: "INS") {
            leaveInsert()
            press(.escape)
            checkLabel("Zurück auf der Seite", indicator, contains: "SEITE")
        }

        press(.space)
        check("Space öffnet das Menü", waitFor(menu))
        press("q")
        checkLabel("Space q schließt das Dokument", indicator, contains: "BIBLIOTHEK", timeout: 8)
        press("g"); press("g")
        check("Bibliothek nimmt nach dem Editor wieder Tasten an", waitFor(focusedItem))
    }

    // MARK: Keys

    private func press(_ key: String, _ flags: XCUIElement.KeyModifierFlags = []) {
        app.typeKey(key, modifierFlags: flags)
        keyPause()
    }
    private func press(_ key: XCUIKeyboardKey) {
        app.typeKey(key, modifierFlags: [])
        keyPause()
    }
    /// The test no longer waits for an idle app: about a person's pace.
    private func keyPause() { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
    /// Line by line, every letter its own key press.
    private func write(_ rows: String...) {
        for (index, row) in rows.enumerated() {
            if index > 0 { press(.return) }
            for letter in row { press(String(letter)) }
        }
    }

    /// Esc, and when it does not arrive ⌃[ and ⌃C, so that the rest still runs.
    private func leaveInsert() {
        press(.escape)
        if checkLabel("Esc: INS → NOR", indicator, contains: "NOR") { return }
        press("[", .control)
        if checkLabel("⌃[: INS → NOR", indicator, contains: "NOR") { return }
        press("c", .control)
        checkLabel("⌃C: INS → NOR", indicator, contains: "NOR")
    }

    // MARK: Elements

    private var indicator: XCUIElement { element("keyboard.indicator") }
    private var menu: XCUIElement { element("keyboard.menu") }
    private var focusedItem: XCUIElement { element("library.focused") }
    private var titleField: XCUIElement { app.textFields["Titel des Textdokuments"] }
    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func item(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ AND identifier BEGINSWITH 'library.'", title)).firstMatch
    }
    /// The text view holding the keys: a text document keeps more than one.
    private func activeText() -> XCUIElement? {
        let focused = app.textViews.matching(NSPredicate(format: "hasKeyboardFocus == true")).firstMatch
        return focused.waitForExistence(timeout: 5) ? focused : nil
    }

    // MARK: Steps

    private func launch(layout: String = "list") {
        app = XCUIApplication()
        // The list: `j` moves one row there, independent of the width of the grid.
        // Hang probe on: the `keyboard` log category lands in the run's artefacts.
        app.launchArguments = ["-notyUITest", "-noty.home.layout", layout, "-noty.diagnostics.hangProbe", "YES",
                               "-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
        app.launch()
        XCTAssertTrue(app.buttons["Alle Unterlagen"].waitForExistence(timeout: 30), "Bibliothek erscheint")
        // The host claims the keys for a while after launch (`KeyboardRouter.reclaim`).
        sleep(2)
    }
    private func fillLibrary(titles: [String]) {
        for title in titles where !item(title).exists { createTextDocument(title) }
    }
    private func createTextDocument(_ title: String) {
        press("n", .shift)
        let sheet = app.navigationBars["Neues Textdokument"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Blatt für „\(title)“")
        titleField.tap()
        titleField.typeText(title)
        app.buttons["Erstellen"].tap()
        XCTAssertTrue(waitGone(sheet), "Blatt für „\(title)“ geht zu")
        XCTAssertTrue(waitFor(item(title)), "„\(title)“ in der Bibliothek")
        sleep(1)
    }
    /// A document of its own, reached by keys alone from the library.
    private func openNewDocument(_ prefix: String) {
        let title = "\(prefix) \(UUID().uuidString.prefix(4))"
        createTextDocument(title)
        press("g"); press("e")
        checkFocus("ge steht auf dem neuen Dokument", title)
        press(.return)
        if !checkLabel("Enter öffnet das Dokument", indicator, contains: "SEITE", timeout: 8) {
            press("o")
            checkLabel("o öffnet das Dokument", indicator, contains: "SEITE", timeout: 15)
        }
        sleep(1)
    }

    // MARK: Checks

    @discardableResult
    private func check(_ what: String, _ passed: Bool, detail: String = "") -> Bool {
        lines.append("\(passed ? "OK    " : "FEHLER") \(what)\(detail.isEmpty ? "" : " (\(detail))")")
        if !passed { XCTFail("\(what) \(detail)") }
        return passed
    }
    @discardableResult
    private func checkLabel(_ what: String, _ element: XCUIElement, contains part: String, timeout: TimeInterval = 3) -> Bool {
        let passed = poll(timeout) { element.exists && element.label.contains(part) }
        return check(what, passed, detail: passed ? "" : "Anzeige: „\(element.exists ? element.label : "fehlt")“")
    }
    private func checkNoLabel(_ what: String, _ element: XCUIElement, _ part: String) {
        check(what, !(element.exists && element.label.contains(part)), detail: element.exists ? "Anzeige: „\(element.label)“" : "")
    }
    private func checkFocus(_ what: String, _ title: String) {
        let passed = poll(3) { focusedItem.exists && focusedItem.label.localizedCaseInsensitiveContains(title) }
        check(what, passed, detail: passed ? "" : "Fokus: „\(focusedItem.exists ? focusedItem.label : "keiner")“")
    }
    private func checkValue(_ what: String, _ element: XCUIElement, _ expected: String, ignoringCase: Bool = false) {
        let passed = poll(3) {
            guard element.exists, let value = element.value as? String else { return false }
            return ignoringCase ? value.lowercased() == expected.lowercased() : value == expected
        }
        check(what, passed, detail: passed ? "" : "Inhalt: \(String(reflecting: element.exists ? element.value as? String ?? "" : "fehlt"))")
    }
    private func waitFor(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool { element.waitForExistence(timeout: timeout) }
    private func waitFor(focused element: XCUIElement, timeout: TimeInterval) -> Bool { poll(timeout) { element.holdsKeys } }
    private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 3) -> Bool { poll(timeout) { !element.exists } }
    private func poll(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < end
        return condition()
    }
    private func shot(_ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// `typeKey` first waits for an idle app, and in an open text it never reports
/// one (two minutes per key, then the timeout). Test bundle only, a private
/// entry point of XCTest; where that is gone the wait simply stays.
private enum NoIdleWait {
    private static let done: Void = {
        guard let process = NSClassFromString("XCUIApplicationProcess") else { return }
        let skip: @convention(block) (AnyObject, Bool, Bool) -> Void = { _, _, _ in }
        for name in ["waitForQuiescenceIncludingAnimationsIdle:isPreEvent:", "waitForQuiescenceIncludingAnimationsIdle:"] {
            if let method = class_getInstanceMethod(process, NSSelectorFromString(name)) {
                method_setImplementation(method, imp_implementationWithBlock(skip))
            }
        }
    }()
    static func install() { _ = done }
}

private extension XCUIElement {
    var holdsKeys: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
