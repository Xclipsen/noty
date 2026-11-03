import SwiftUI
import UIKit
import NotebookCore

struct LawReaderView: View {
    @EnvironmentObject var laws: LawLibraryModel
    /// State of the law window the reader may be shown in.
    @EnvironmentObject var panel: LawPanelModel
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// Shown in the notebook's law window, which can be closed or stashed.
    var inPanel = false
    var pen = LawPenMode()
    /// Lets the reader switch what Apple Pencil does; nil hides the switch.
    var onPenChange: ((LawPenMode) -> Void)? = nil
    @StateObject var textSelection = LawTextSelection()
    /// Interface of the marking controls for subviews (LawMarkController.swift).
    @StateObject var markController = LawMarkController()
    @State var query = ""
    @State var number = ""
    @State var letters = false
    @State var selectedID = ""
    @State var versionID = ""
    @State var document: LawDocument?
    @State var sectionID = ""
    @State var pdfURL: URL?
    @State var viewPDF = false
    @State var pdfPage = 1
    @State var pdfTarget: Int?
    @State var loadError = ""
    @State var loading = false
    @State var showContents = false
    @State var showBookmarks = false
    /// `t`: the law list, otherwise the bar's menu.
    @State var showLaws = false
    /// Keyboard mode: set while the reader has the keys.
    @State var keyPanel: KeyPanel?
    @State var inputField = HelixLawField.query
    /// Reading size of the law text, kept across sections, notebooks and launches.
    @AppStorage("noty.laws.fontSize") var fontSize = 18.0
    @State var jumpParagraph: String?
    @State var requestID = UUID()
    @FocusState var queryFocused: Bool
    /// Closed or stashed at the screen edge: no hidden field may keep the keyboard.
    var hidden: Bool { inPanel && (!panel.isOpen || panel.stashed) }
    @State private var errorsShownHere = false
    /// While the reader is visible it shows `laws.error` itself.
    private func showErrors(_ shown: Bool) {
        guard shown != errorsShownHere else { return }
        errorsShownHere = shown
        laws.inlineErrorPages += shown ? 1 : -1
    }
    var entry: LawEntry? { laws.entries.first { $0.id == selectedID } }
    var section: LawSection? { document?.sections.first { $0.id == sectionID } }
    var marks: [LawPersonalItem] {
        laws.items.filter { !$0.deleted && $0.payload["lawId"]?.string == selectedID && $0.payload["versionId"]?.string == document?.version }
    }
    private var textMarks: [LawTextMark] {
        guard let section else { return [] }
        return marks.compactMap { item in
            guard item.kind == "annotation", case let .object(a) = item.payload["anchor"], a["sectionId"]?.string == section.id,
                  let start = a["start"]?.int, let end = a["end"]?.int, let quote = a["quote"]?.string else { return nil }
            return LawTextMark(id: item.id, anchor: LawAnchor(sectionId: section.id, start: start, end: end, quote: quote), color: item.payload["color"]?.string)
        }
    }
    var bookmarkItem: LawPersonalItem? {
        guard let section else { return nil }
        return marks.first { item in
            item.kind == "bookmark" && item.payload["sectionId"]?.string == section.id
                && item.payload["view"]?.string == (viewPDF ? "pdf" : "text") && (!viewPDF || item.payload["page"]?.int == pdfPage)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if loading { ProgressView("Wird geladen …").padding() }
            if !loadError.isEmpty { Text(loadError).font(.caption).foregroundStyle(.orange).padding(8) }
            // The app-level alert cannot appear over an open notebook: show it here.
            if let error = laws.error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("OK") { laws.error = nil }.font(.caption)
                }.padding(8)
            }
            if let section, let doc = document {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.label).font(.headline)
                        Text(section.title).font(.subheadline).lineLimit(2)
                    }
                    Spacer()
                    Button { toggleBookmark() } label: { Image(systemName: bookmarkItem == nil ? "bookmark" : "bookmark.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel(bookmarkItem == nil ? "Fundstelle als Lesezeichen speichern" : "Lesezeichen entfernen")
                }.padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 2)
                if viewPDF, let pdfURL {
                    NativeLawPDF(url: pdfURL, page: pdfTarget ?? section.pdf?.page ?? 1, top: pdfTarget == nil ? (section.pdf?.top ?? 0) : 0, selection: textSelection, onPage: { pdfPage = $0 },
                        items: marks.filter { $0.kind == "annotation" }, pen: pen,
                        onMark: { payload in
                            var payload = payload.merging(basePayload(doc)) { _, new in new }
                            payload["color"] = .string(pen.hex)
                            Task { await laws.save(kind: "annotation", payload: payload) }
                        }, onRemove: { unmark($0) })
                        .id(pdfURL)
                } else {
                    NativeLawText(text: section.text, html: section.html, notes: section.notes, sectionID: section.id, fontSize: fontSize,
                        marks: textMarks, paragraph: jumpParagraph, selection: textSelection, pen: pen,
                        onMark: { mark($0) }, onRemove: { unmark($0) })
                        .overlay(alignment: .bottom) { if textSelection.active { selectionBar } }
                }
                footer(doc, section: section)
            } else if !loading {
                ContentUnavailableView(laws.entries.isEmpty ? "Noch keine Gesetze geladen" : "Gesetz wählen", systemImage: "books.vertical", description: Text(laws.entries.isEmpty ? "Unter Einstellungen › Gesetzessammlung den Offlinebestand laden." : "Ein Gesetz antippen oder zum Beispiel nach 144 HGB suchen."))
            }
        }
        .background(Color(uiColor: .systemBackground))
        .task { await laws.start(); await openInitial() }
        .onChange(of: laws.entries.count) { _, _ in Task { await openInitial() } }
        .onChange(of: "\(selectedID)|\(sectionID)") { _, _ in
            guard !selectedID.isEmpty, !sectionID.isEmpty else { return }
            LawReadingPosition.remember(law: selectedID, section: sectionID)
        }
        .task(id: query) {
            guard !query.isEmpty else { return }
            loadError = ""
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            // While typing only a complete „144 HGB“ jumps: a bare „144“ may
            // still become that and must not move the reader (and its saved
            // place) to § 144 of the open law. Return searches it.
            await search(query, bareReference: false, from: .query)
        }
        .task(id: number) {
            // The field following the reader (arrows, contents) is no new lookup.
            guard !number.isEmpty, !showsCurrentSection(number) else { return }
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            await search(number, from: .number)
        }
        .onChange(of: hidden) { _, hidden in
            if hidden { queryFocused = false; textSelection.clear(); leaveKeys() }
            showErrors(!hidden)
        }
        .onChange(of: laws.keyFocus) { _, _ in if inPanel { startKeys() } }
        .onAppear { showErrors(!hidden) }
        .onDisappear { showErrors(false); leaveKeys() }
        .onAppear { connectMarkController() }
        .onChange(of: pen) { _, _ in connectMarkController() }
        .onChange(of: lastAnnotation?.id, initial: true) { _, id in markController.update(canUndo: id != nil) }
        .onDisappear { markController.disconnect() }
        .sheet(isPresented: $showContents) { contents.keyboardSheet() }
        .sheet(isPresented: $showBookmarks) { bookmarks.keyboardSheet() }
        .sheet(isPresented: $showLaws) { lawList.keyboardSheet() }
        // Last, so the sheets above receive it as well.
        .environmentObject(markController)
    }
}
