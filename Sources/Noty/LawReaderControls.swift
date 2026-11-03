import SwiftUI
import UIKit
import NotebookCore

extension LawReaderView {
    var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Menu {
                    ForEach(laws.entries) { entry in Button("\(entry.abbr) · \(entry.name)") { Task { await choose(entry) } } }
                } label: { Label(entry?.abbr ?? "Gesetz wählen", systemImage: "books.vertical").lineLimit(1) }
                Spacer()
                // Directly in the bar, not in a menu: several taps in a row stay quick.
                if !viewPDF {
                    Button { fontSize = max(12, fontSize - 2) } label: { Image(systemName: "textformat.size.smaller").frame(minWidth: 30, minHeight: 32) }
                        .disabled(fontSize <= 12).accessibilityLabel("Schrift kleiner")
                    Button { fontSize = min(32, fontSize + 2) } label: { Image(systemName: "textformat.size.larger").frame(minWidth: 30, minHeight: 32) }
                        .disabled(fontSize >= 32).accessibilityLabel("Schrift größer")
                }
                Button { showContents = true } label: { Image(systemName: "list.bullet") }.accessibilityLabel("Inhaltsverzeichnis")
                Button { showBookmarks = true } label: { Image(systemName: "bookmark") }.accessibilityLabel("Lesezeichen und Markierungen")
                Menu {
                    if let entry {
                        ForEach(entry.versions) { v in
                            Button(v.status.last ?? v.id) { Task { await open(entry, version: v.id, target: sectionID, resume: true) } }
                        }
                    }
                    Divider()
                    if let last = marks.last(where: { $0.kind == "annotation" }) {
                        Button("Letzte Markierung rückgängig", systemImage: "arrow.uturn.backward") { Task { await laws.remove(last) } }
                    }
                    Divider()
                    // Marking never needs an account; the account only syncs.
                    if let user = laws.user, !laws.sessionExpired {
                        Text("Angemeldet als \(user.email ?? user.name) · \(laws.syncStatus)")
                    } else {
                        Text("Nicht angemeldet · Markierungen bleiben auf diesem iPad. Konto unter Einstellungen › Konto.")
                    }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Fassung und Markierungen")
            }
            HStack {
                TextField("Schnellsuche · 144 HGB", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .focused($queryFocused)
                    .onSubmit { Task { await search(query, allowFullText: true, from: .query) } }
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Suche leeren") }
            }.padding(8).background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                LawParagraphField(placeholder: entry?.kind == "administration" ? "Abschnitt / R" : "Paragraph", text: $number, letters: letters, active: !hidden) {
                    Task { await search(number, allowFullText: true, from: .number) }
                }
                // A UITextField otherwise takes all offered height and pushes
                // the law text down (empty box under the quick search).
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 32)
                Button(letters ? "123" : "abc / Abs.") { letters.toggle() }.font(.caption)
                    .accessibilityLabel("Zwischen Zahlen- und Texttastatur wechseln")
                Button(viewPDF ? "Lesetext" : "PDF") { Task { await togglePDF() } }.disabled(document == nil)
            }.padding(8).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            if let onPenChange { penSwitch(onPenChange) }
        }.padding(10).buttonStyle(.borderless)
    }
    /// Website-style pagination with the neighbouring labels as large targets;
    /// the version note and source sit above it instead of between the arrows.
    func footer(_ doc: LawDocument, section: LawSection) -> some View {
        let index = doc.sections.firstIndex { $0.id == section.id } ?? 0
        let previous = doc.sections.indices.contains(index - 1) ? doc.sections[index - 1] : nil
        let next = doc.sections.indices.contains(index + 1) ? doc.sections[index + 1] : nil
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(doc.status.last ?? doc.version).lineLimit(1)
                if doc.version != entry?.currentVersion { Text("Ältere Fassung").foregroundStyle(.orange).fixedSize() }
                if let source = URL(string: doc.sourceUrl), source.scheme == "https" { Link("Quelle", destination: source).fixedSize() }
            }.font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { move(-1) } label: {
                    Label(previous?.label ?? "Anfang", systemImage: "chevron.left").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(previous == nil)
                .accessibilityLabel(previous.map { "Vorherige Vorschrift: \($0.label)" } ?? "Keine vorherige Vorschrift")
                Text("\(index + 1) / \(doc.sections.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                Button { move(1) } label: {
                    HStack(spacing: 6) { Text(next?.label ?? "Ende").lineLimit(1); Image(systemName: "chevron.right") }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .disabled(next == nil)
                .accessibilityLabel(next.map { "Nächste Vorschrift: \($0.label)" } ?? "Keine nächste Vorschrift")
            }
            .buttonStyle(.bordered)
        }.padding(.horizontal, 10).padding(.vertical, 8)
    }
    func move(_ direction: Int) {
        guard let sections = document?.sections, let i = sections.firstIndex(where: { $0.id == sectionID }), sections.indices.contains(i + direction) else { return }
        textSelection.clear()
        pdfTarget = nil; sectionID = sections[i + direction].id; jumpParagraph = nil; loadError = ""
        follow(sections[i + direction])
        // Without a PDF position the PDF view would silently fall back to page 1.
        if viewPDF, sections[i + direction].pdf == nil {
            viewPDF = false; loadError = "Keine PDF-Fundstelle für diese Vorschrift; der Lesetext wird angezeigt."
        }
    }
    /// Both fields describe where the reader is. After arrows, contents,
    /// bookmarks or another law the paragraph field shows the new section's
    /// number and a quick-search location that no longer applies is cleared;
    /// the field a lookup was typed into keeps its input (e.g. „4 Abs. 2“).
    func follow(_ shown: LawSection?, from field: LawLookupField? = nil) {
        if field != .number { number = shown?.keys.first ?? "" }
        if field != .query, !query.isEmpty,
           LawQuickTarget.parse(query, entries: laws.entries) != nil || LawReference.parse(query) != nil { query = "" }
    }
    /// `value` names the shown section without a paragraph, so a lookup would
    /// change nothing (in particular the paragraph field following the reader).
    func showsCurrentSection(_ value: String) -> Bool {
        guard let section, let ref = LawReference.parse(value), ref.paragraph == nil else { return false }
        return section.keys.contains(ref.key)
    }
}

private struct LawParagraphField: UIViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var letters: Bool
    var active: Bool
    var submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(); field.delegate = context.coordinator
        field.autocorrectionType = .no; field.autocapitalizationType = .none
        field.returnKeyType = .search
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        let bar = UIToolbar(); bar.sizeToFit()
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), UIBarButtonItem(title: "Suchen", style: .done, target: context.coordinator, action: #selector(Coordinator.search))]
        field.inputAccessoryView = bar
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.placeholder = placeholder
        if field.text != text { field.text = text }
        let type: UIKeyboardType = letters ? .default : .numberPad
        if field.keyboardType != type { field.keyboardType = type; if field.isFirstResponder { field.reloadInputViews() } }
        if !active, field.isFirstResponder { field.resignFirstResponder() }
    }
    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: LawParagraphField
        init(_ parent: LawParagraphField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        @objc func search() { parent.submit() }
        /// The field shows the current section: typing replaces that number.
        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async {
                textField.selectedTextRange = textField.textRange(from: textField.beginningOfDocument, to: textField.endOfDocument)
            }
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { parent.submit(); return true }
    }
}
