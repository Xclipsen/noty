import SwiftUI
import PencilKit
import NotebookCore

/// Termindetails: Titel → Datum/Uhrzeit → Kalender → Ort → Beschreibung →
/// „Notizen“ with a directly writable page. `overlay`: large view over the
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
    @State private var detailsHeight: CGFloat = 220
    private var calendar: Calendar { model.calendar }

    var body: some View {
        VStack(spacing: 0) {
            bar
            Divider()
            GeometryReader { geo in
                // Wide overlay: details beside the page; otherwise stacked.
                if overlay && geo.size.width >= 760 {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView { details.padding(20) }.frame(width: 340)
                        Divider()
                        notes.padding(16)
                    }
                } else {
                    VStack(spacing: 0) {
                        // As tall as the details, at most 40 %: the page keeps most of the room.
                        ScrollView {
                            details.padding(16)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
                        }
                        .frame(height: min(detailsHeight, max(160, geo.size.height * 0.4)))
                        Divider()
                        notes.padding(.horizontal, 14).padding(.vertical, 10)
                    }
                }
            }
        }
        .background(Color(uiColor: overlay ? .systemBackground : .secondarySystemBackground))
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

    private var bar: some View {
        HStack {
            if overlay {
                Button { model.selection = nil } label: {
                    Label("Kalender", systemImage: "chevron.backward").font(.body.weight(.semibold))
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Zurück zum Kalender")
                .keyboardShortcut(escapes ? .cancelAction : nil)
                Spacer()
                Text(CalendarText.shortDate(event.start, calendar: calendar)).font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Termin").font(.headline)
                Spacer()
                Button { model.selection = nil } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Details schließen")
                .keyboardShortcut(escapes ? .cancelAction : nil)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 50)
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(event.title).font(.title2.bold()).strikethrough(event.status == .cancelled)
                    .accessibilityAddTraits(.isHeader)
                badges
            }
            detailRow("calendar", CalendarText.longDate(event.start, calendar: calendar))
            detailRow("clock", event.timeText(calendar))
            HStack(spacing: 10) {
                Circle().fill(CalendarPalette.color(event)).frame(width: 10, height: 10).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.source.title)
                    Text(event.source.origin).font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            if let room = event.room { detailRow("mappin.and.ellipse", room) }
            if let teacher = event.teacher { detailRow("person", teacher) }
            if case .substitution(let note) = event.status { detailRow("arrow.triangle.swap", note) }
            if let text = event.repeatText { detailRow("repeat", text) }
            detailRow(event.reminder == nil ? "bell.slash" : "bell", event.reminder ?? "Keine Erinnerung")
            if let text = event.details {
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if event.writable {
                HStack(spacing: 12) {
                    Button { model.draft = CalendarDraft(editing: event, calendar: calendar) } label: {
                        Label("Bearbeiten", systemImage: "pencil").frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    Button(role: .destructive) { confirmingRemoval = true } label: {
                        Label("Löschen", systemImage: "trash").frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var badges: some View {
        HStack(spacing: 6) {
            if let label = event.status.label, let symbol = event.status.symbol {
                badge(label, symbol, tint: event.status == .cancelled ? .orange : .primary)
            }
            if event.source.readOnly {
                badge(event.source == .timetable ? "Schreibgeschützt · WebUntis" : "Schreibgeschützt", "lock", tint: .secondary)
            } else {
                badge("Bearbeitbar", "pencil", tint: .secondary)
            }
        }
    }

    private func badge(_ text: String, _ symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    private func detailRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Notes

    private var notes: some View {
        let pages = model.pages(for: event)
        let index = min(page, pages.count - 1)
        let written = model.hasNotes(event)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Notizen").font(.headline).accessibilityAddTraits(.isHeader)
                if written {
                    Label("Inhalt vorhanden", systemImage: "note.text").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { enlarge(index) } label: {
                    Label("Vergrößern", systemImage: "arrow.up.left.and.arrow.down.right").frame(minHeight: 44)
                }
                .help("Notiz groß öffnen")
            }
            CalendarNoteControls(pages: pages.count, page: Binding(get: { index }, set: { page = $0 }), input: $input) {
                page = model.addPage(to: event)
            }
            CalendarNotePageView(event: event, model: model, page: index, input: input)
            Text(written ? "Im Entwurf nur bis zum Neustart · später als „\(event.noteTitle(calendar))“ in „Kalendernotizen“"
                         : "Leere Seite: noch keine Notiz · erst die erste Eingabe legt später ein Heft an")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

enum CalendarNoteInput: String, CaseIterable, Identifiable {
    case pen, text
    var id: String { rawValue }
    var title: String { self == .pen ? "Stift" : "Tippen" }
    var symbol: String { self == .pen ? "pencil.tip" : "keyboard" }
}

/// Page count and flipping, adding a page, input mode.
struct CalendarNoteControls: View {
    let pages: Int
    @Binding var page: Int
    @Binding var input: CalendarNoteInput
    let addPage: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button { page = max(0, page - 1) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .disabled(page == 0)
            .accessibilityLabel("Vorherige Seite")
            Text("Seite \(page + 1) von \(pages)").font(.subheadline).monospacedDigit()
                .accessibilityAddTraits(.updatesFrequently)
            Button { page = min(pages - 1, page + 1) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .disabled(page >= pages - 1)
            .accessibilityLabel("Nächste Seite")
            Button(action: addPage) {
                Image(systemName: "plus.rectangle.portrait").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Seite hinzufügen")
            .help("Seite hinzufügen")
            Spacer(minLength: 8)
            Picker("Eingabe", selection: $input) {
                ForEach(CalendarNoteInput.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 190)
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
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
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
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Label("Zurück zu \(event.title) · \(CalendarText.shortDate(event.start, calendar: model.calendar))",
                          systemImage: "chevron.backward")
                        .font(.body.weight(.semibold)).lineLimit(1).frame(minHeight: 44).contentShape(Rectangle())
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Text(event.noteTitle(model.calendar)).font(.headline).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            CalendarNoteControls(pages: pages.count, page: $page, input: $input) {
                page = model.addPage(to: event)
            }
            .padding(.horizontal, 16)
            Divider()
            CalendarNotePageView(event: event, model: model, page: min(page, pages.count - 1), input: input)
                .padding(20)
            Text("Großansicht (Entwurf, nichts wird gespeichert). Ab Stufe B öffnet „Vergrößern“ den normalen noty-Editor.")
                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
        }
        .background(Color(uiColor: .systemBackground))
        .preferredColorScheme(.dark)
    }
}
