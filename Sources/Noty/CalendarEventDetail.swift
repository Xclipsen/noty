import SwiftUI
import PencilKit
import NotebookCore

/// Termindetails: a minimal head (Titel, Datum/Uhrzeit, Kalender, Ort),
/// only the rows that have content, then „Notizen“ with the directly
/// writable page as the main element. `overlay`: large view over the
/// calendar in narrow windows, with a clear way back.
struct CalendarEventPanel: View {
    let event: CalendarSampleEvent
    @ObservedObject var model: CalendarDesignModel
    var overlay = false
    /// Esc closes the panel only while nothing is presented over the calendar.
    var escapes = true
    let enlarge: (Int) -> Void
    @State private var page = 0
    @State private var input = CalendarNoteInput.pen
    @State private var confirmingRemoval = false
    @State private var detailsHeight: CGFloat = 160
    private var calendar: Calendar { model.calendar }

    var body: some View {
        VStack(spacing: 0) {
            bar
            GeometryReader { geo in
                // Wide overlay: details beside the page; otherwise stacked.
                if overlay && geo.size.width >= 760 {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView { details.padding(CalendarSpace.xl) }.frame(width: 320)
                        Rectangle().fill(CalendarPalette.hairline).frame(width: 0.5)
                        notes.padding(CalendarSpace.l)
                    }
                } else {
                    VStack(spacing: 0) {
                        // As tall as the details, at most a third: the page keeps the room.
                        ScrollView {
                            details.padding(.horizontal, CalendarSpace.l).padding(.bottom, CalendarSpace.m)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
                        }
                        .frame(height: min(detailsHeight, max(120, geo.size.height * 0.34)))
                        Rectangle().fill(CalendarPalette.hairline).frame(height: 0.5)
                        notes.padding(.horizontal, CalendarSpace.m).padding(.vertical, CalendarSpace.s)
                    }
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .onChange(of: event.id) { _, _ in page = 0 }
        .confirmationDialog("Termin löschen?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            if event.seriesID != nil {
                Button("Nur diesen Termin löschen", role: .destructive) { model.remove(event, wholeSeries: false) }
                Button("Gesamte Serie löschen", role: .destructive) { model.remove(event, wholeSeries: true) }
            } else {
                Button("Termin löschen", role: .destructive) { model.remove(event, wholeSeries: false) }
            }
        } message: {
            Text("Entwurf: Der Termin wird nur in dieser Sitzung ausgeblendet und lässt sich zurückholen. Notizen bleiben erhalten.")
        }
    }

    /// Back/close and, for own entries, one menu with Bearbeiten/Löschen.
    private var bar: some View {
        HStack(spacing: 0) {
            if overlay {
                Button { model.selection = nil } label: {
                    Label("Kalender", systemImage: "chevron.backward").font(.body.weight(.medium))
                        .padding(.horizontal, CalendarSpace.xs)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Zurück zum Kalender")
                .keyboardShortcut(escapes ? .cancelAction : nil)
            }
            Spacer()
            if event.writable {
                Menu {
                    Button { model.draft = CalendarDraft(editing: event, calendar: calendar) } label: {
                        Label("Bearbeiten", systemImage: "pencil")
                    }
                    Button(role: .destructive) { confirmingRemoval = true } label: {
                        Label("Löschen", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.body).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Termin bearbeiten oder löschen")
            }
            if !overlay {
                Button { model.selection = nil } label: {
                    Image(systemName: "xmark").font(.body.weight(.medium)).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Details schließen")
                .keyboardShortcut(escapes ? .cancelAction : nil)
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, CalendarSpace.xs)
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: CalendarSpace.s) {
            Text(event.title).font(.title3.weight(.semibold)).strikethrough(event.status == .cancelled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 3) {
                Text(CalendarText.longDate(event.start, calendar: calendar) + " · " + event.timeText(calendar)).monospacedDigit()
                if let place = [event.room, event.teacher].compactMap({ $0 }).joined(separator: " · ").nilIfEmpty {
                    Text(place)
                }
                HStack(spacing: 6) {
                    Circle().fill(CalendarPalette.color(event)).frame(width: 7, height: 7)
                    Text(event.source.readOnly ? "\(event.source.title) · \(event.source.origin)" : event.source.title)
                    if event.source.readOnly { Image(systemName: "lock").font(.caption2).accessibilityLabel("schreibgeschützt") }
                }
                .accessibilityElement(children: .combine)
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let label = event.status.label, let symbol = event.status.symbol {
                Label(statusText(label), systemImage: symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(event.status == .cancelled ? Color.orange : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Only rows with content; „keine Erinnerung“ is not shown.
            if event.repeatText != nil || event.reminder != nil {
                VStack(alignment: .leading, spacing: 3) {
                    if let text = event.repeatText { Label(text, systemImage: "repeat") }
                    if let text = event.reminder { Label(text, systemImage: "bell") }
                }
                .font(.footnote).foregroundStyle(.secondary).labelStyle(CalendarCompactLabelStyle())
            }
            if let text = event.details {
                Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusText(_ label: String) -> String {
        if case .substitution(let note) = event.status { return "\(label): \(note)" }
        return label
    }

    // MARK: Notes

    private var notes: some View {
        let pages = model.pages(for: event)
        let index = min(page, pages.count - 1)
        return VStack(alignment: .leading, spacing: CalendarSpace.xs) {
            CalendarNoteControls(pages: pages.count, page: Binding(get: { index }, set: { page = $0 }), input: $input,
                                 addPage: { page = model.addPage(to: event) }, enlarge: { enlarge(index) })
            CalendarNotePageView(event: event, model: model, page: index, input: input)
            Text("Entwurf · wird nicht gespeichert")
                .font(.caption2).foregroundStyle(CalendarPalette.quiet).lineLimit(1)
                .frame(maxWidth: .infinity)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Small icon + text with tight spacing for metadata rows.
struct CalendarCompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.frame(width: 16)
            configuration.title
        }
    }
}

enum CalendarNoteInput: String, CaseIterable, Identifiable {
    case pen, text
    var id: String { rawValue }
    var title: String { self == .pen ? "Stift" : "Tippen" }
    var symbol: String { self == .pen ? "pencil.tip" : "keyboard" }
}

/// One quiet row above the page: „Notizen“, input mode, page flip (only
/// with several pages), add page and enlarge.
struct CalendarNoteControls: View {
    let pages: Int
    @Binding var page: Int
    @Binding var input: CalendarNoteInput
    let addPage: () -> Void
    var enlarge: (() -> Void)?

    var body: some View {
        // Narrow panel with several pages: the „Notizen“ caption yields first.
        ViewThatFits(in: .horizontal) {
            row(caption: true)
            row(caption: false)
        }
        .font(.body)
        .buttonStyle(.borderless)
    }

    private func row(caption: Bool) -> some View {
        HStack(spacing: 0) {
            if caption {
                Text("Notizen").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    .fixedSize().padding(.trailing, CalendarSpace.s)
            }
            Picker("Eingabe", selection: $input) {
                ForEach(CalendarNoteInput.allCases) { Label($0.title, systemImage: $0.symbol).labelStyle(.iconOnly).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 92)
            .accessibilityLabel("Eingabe: \(input.title)")
            Spacer(minLength: CalendarSpace.s)
            if pages > 1 {
                Button { page = max(0, page - 1) } label: {
                    Image(systemName: "chevron.left").frame(width: 36, height: 44).contentShape(Rectangle())
                }
                .disabled(page == 0)
                .accessibilityLabel("Vorherige Seite")
                Text("\(page + 1)/\(pages)").font(.footnote).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                    .accessibilityLabel("Seite \(page + 1) von \(pages)")
                    .accessibilityAddTraits(.updatesFrequently)
                Button { page = min(pages - 1, page + 1) } label: {
                    Image(systemName: "chevron.right").frame(width: 36, height: 44).contentShape(Rectangle())
                }
                .disabled(page >= pages - 1)
                .accessibilityLabel("Nächste Seite")
            }
            Button(action: addPage) {
                Image(systemName: "plus.rectangle.portrait").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Seite hinzufügen")
            .help("Seite hinzufügen")
            if let enlarge {
                Button(action: enlarge) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Vergrößern")
                .help("Notiz groß öffnen")
            }
        }
    }
}

/// A4 page in canonical page points, scaled to the available space; the
/// same page shows inline and enlarged without changing its content.
struct CalendarNotePageView: View {
    let event: CalendarSampleEvent
    @ObservedObject var model: CalendarDesignModel
    let page: Int
    let input: CalendarNoteInput
    static let size = CGSize(width: 595, height: 842)
    @FocusState private var typing: Bool

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / Self.size.width, geo.size.height / Self.size.height)
            let size = CGSize(width: Self.size.width * scale, height: Self.size.height * scale)
            let pages = model.pages(for: event)
            let current = pages.indices.contains(page) ? pages[page] : CalendarNotePage()
            ZStack(alignment: .topLeading) {
                Color.white
                CalendarRuling(scale: scale).allowsHitTesting(false)
                TextEditor(text: Binding(get: { current.text }, set: { model.setText($0, page: page, of: event) }))
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(Color.black)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 40 * scale).padding(.top, 36 * scale)
                    .focused($typing)
                    .allowsHitTesting(input == .text)
                    .environment(\.colorScheme, .light)
                    .accessibilityLabel("Text der Notizseite \(page + 1)")
                CalendarNoteCanvas(drawing: current.drawing, revision: current.revision, scale: scale, interactive: input == .pen) {
                    model.setDrawing($0, page: page, of: event)
                }
                .allowsHitTesting(input == .pen)
                .accessibilityLabel("Handschrift der Notizseite \(page + 1)")
                if current.isEmpty && !typing {
                    Text(input == .pen ? "Direkt mit dem Pencil schreiben" : "Tippen, um Text zu schreiben")
                        .font(.system(size: 15 * scale)).foregroundStyle(Color.black.opacity(0.3))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: input) { _, value in typing = value == .text }
        }
        // A new canvas per event and page: late callbacks can never write into another page.
        .id("\(event.id)-\(page)")
    }
}

/// Light lines so the mock reads as a page; no grid in the calendar itself.
private struct CalendarRuling: View {
    let scale: CGFloat
    var body: some View {
        Canvas { context, size in
            var y = 72 * scale
            while y < size.height - 24 * scale {
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                               with: .color(Color(red: 0.75, green: 0.82, blue: 0.92).opacity(0.6)), lineWidth: 0.5)
                y += 24 * scale
            }
        }
    }
}

/// Handwriting on the page (PencilKit, black pen), kept in canonical
/// page coordinates through the canvas zoom.
struct CalendarNoteCanvas: UIViewRepresentable {
    let drawing: PKDrawing
    let revision: Int
    let scale: CGFloat
    let interactive: Bool
    let changed: (PKDrawing) -> Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Black ink stays black on the white page in the dark app.
        canvas.overrideUserInterfaceStyle = .light
        // Design stage without the editor's tool bar: finger and Pencil write.
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 2)
        canvas.isScrollEnabled = false
        canvas.bounces = false; canvas.bouncesZoom = false
        canvas.delegate = context.coordinator
        context.coordinator.applying = true
        canvas.drawing = drawing
        context.coordinator.applying = false
        context.coordinator.seen = revision
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.changed = changed
        canvas.isUserInteractionEnabled = interactive
        if abs(canvas.zoomScale - scale) > 0.0001 || canvas.minimumZoomScale != scale {
            canvas.minimumZoomScale = scale; canvas.maximumZoomScale = scale
            canvas.setZoomScale(scale, animated: false)
            canvas.pinchGestureRecognizer?.isEnabled = false
        }
        let size = CGSize(width: CalendarNotePageView.size.width * scale, height: CalendarNotePageView.size.height * scale)
        if canvas.contentSize != size { canvas.contentSize = size }
        if canvas.contentOffset != .zero { canvas.contentOffset = .zero }
        // Written elsewhere (the enlarged page): take it over once.
        if coordinator.seen != revision {
            coordinator.applying = true
            canvas.drawing = drawing
            coordinator.applying = false
            coordinator.seen = revision
        }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var seen = 0
        var applying = false
        var changed: ((PKDrawing) -> Int)?

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !applying, let changed else { return }
            seen = changed(canvasView.drawing)
        }
    }
}

/// „Vergrößern“: the page large, with a clear way back to event and date.
/// From Stufe B on this opens the normal noty editor.
struct CalendarEnlargedNote: View {
    let event: CalendarSampleEvent
    @ObservedObject var model: CalendarDesignModel
    @State var page: Int
    @State private var input = CalendarNoteInput.pen
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let pages = model.pages(for: event)
        VStack(spacing: 0) {
            HStack(spacing: CalendarSpace.m) {
                Button { dismiss() } label: {
                    Label("\(event.title) · \(CalendarText.shortDate(event.start, calendar: model.calendar))",
                          systemImage: "chevron.backward")
                        .font(.body.weight(.medium)).lineLimit(1).frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Zurück zu \(event.title), \(CalendarText.longDate(event.start, calendar: model.calendar))")
                .keyboardShortcut(.cancelAction)
                .layoutPriority(1)
                CalendarNoteControls(pages: pages.count, page: $page, input: $input) {
                    page = model.addPage(to: event)
                }
                .frame(maxWidth: 420)
            }
            .padding(.horizontal, CalendarSpace.l)
            Rectangle().fill(CalendarPalette.hairline).frame(height: 0.5)
            CalendarNotePageView(event: event, model: model, page: min(page, pages.count - 1), input: input)
                .padding(CalendarSpace.xl)
            Text("Entwurf · wird nicht gespeichert · ab Stufe B öffnet hier der normale noty-Editor")
                .font(.caption2).foregroundStyle(CalendarPalette.quiet).lineLimit(1).padding(.bottom, CalendarSpace.s)
        }
        .background(Color(uiColor: .systemBackground))
        .preferredColorScheme(.dark)
    }
}
