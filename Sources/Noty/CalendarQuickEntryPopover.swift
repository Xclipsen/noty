import SwiftUI
import NotebookCore

/// „Schnell anlegen“ behind „+“ (⌥⌘N): one line of text, a live preview of
/// what noty understood (title, day, time), Enter opens the pre-filled form
/// (`requestQuickEvent`). Nothing is saved here – the form decides.
struct CalendarQuickEntryPopover: View {
    @ObservedObject var model: CalendarModel
    let close: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool
    /// What to do once the popover is gone (a sheet cannot open while it is still on screen).
    @State private var pending: (@MainActor () -> Void)?

    var body: some View {
        let draft = model.quickDraft(text)
        VStack(alignment: .leading, spacing: CalendarSpace.m) {
            Text("Neuer Termin").font(.headline)
            TextField("z. B. Mathe Klausur Fr 10 Uhr", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .onSubmit { open(draft) }
                .accessibilityHint("Eingabe öffnet das vorausgefüllte Formular")
            preview(draft)
            HStack {
                Button("Leeres Formular") {
                    pending = { [model] in model.requestNewEvent() }
                    close()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Weiter") { open(draft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == nil)
            }
            .font(.subheadline.weight(.semibold))
            Text("Versteht heute, morgen, Wochentage, Daten wie 12.11. und Uhrzeiten wie 10 Uhr, 10:30 oder 10–12 Uhr. Ohne Uhrzeit ganztägig.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(CalendarSpace.l)
        .frame(width: 360)
        .presentationCompactAdaptation(.popover)
        .preferredColorScheme(.dark)
        .defaultFocus($focused, true)
        .onAppear {
            // Popovers often ignore an immediate focus request.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                focused = true
            }
        }
        // Runs after the popover left the screen: then the form sheet can open.
        .onDisappear {
            let action = pending
            pending = nil
            action?()
        }
    }

    @ViewBuilder private func preview(_ draft: CalendarDraft?) -> some View {
        let calendar = model.calendar
        HStack(alignment: .top, spacing: CalendarSpace.m) {
            Image(systemName: draft == nil ? "text.cursor" : "calendar.badge.plus")
                .font(.title3).foregroundStyle(draft == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint)).frame(width: 28)
                .accessibilityHidden(true)
            if let draft {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.title.isEmpty ? "Ohne Titel" : draft.title).font(.subheadline.weight(.semibold))
                        .foregroundStyle(draft.title.isEmpty ? .secondary : .primary)
                    Text(CalendarText.longDate(draft.start, calendar: calendar) + " · "
                         + (draft.allDay ? "ganztägig" : CalendarText.timeRange(draft.start, draft.end, calendar: calendar)))
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Erkannt: " + (draft.title.isEmpty ? "ohne Titel" : draft.title) + ", "
                                    + CalendarText.longDate(draft.start, calendar: calendar))
            } else {
                Text("Titel, Tag und Uhrzeit in einer Zeile eingeben.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(CalendarSpace.s)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func open(_ draft: CalendarDraft?) {
        guard draft != nil else { return }
        let line = text
        pending = { [model] in model.requestQuickEvent(line) }
        close()
    }
}
