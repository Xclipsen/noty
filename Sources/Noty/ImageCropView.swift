import SwiftUI
import NotebookCore

/// Crop edits a normalized rectangle; applying never rewrites the original file.
struct ImageCropView: View {
    let image: UIImage
    let onApply: (PageRect) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var left: Double
    @State private var right: Double
    @State private var top: Double
    @State private var bottom: Double

    init(image: UIImage, crop: PageRect, onApply: @escaping (PageRect) -> Void) {
        self.image = image; self.onApply = onApply
        _left = State(initialValue: crop.x); _right = State(initialValue: 1 - crop.x - crop.width)
        _top = State(initialValue: crop.y); _bottom = State(initialValue: 1 - crop.y - crop.height)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    GeometryReader { geometry in
                        let scale = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                        let w = image.size.width * scale, h = image.size.height * scale
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: image).resizable().frame(width: w, height: h)
                            Path { path in
                                path.addRect(CGRect(x: 0, y: 0, width: w, height: h))
                                path.addRect(CGRect(x: w * left, y: h * top,
                                    width: w * (1 - left - right), height: h * (1 - top - bottom)))
                            }.fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
                            Rectangle().stroke(.white, lineWidth: 2)
                                .frame(width: w * (1 - left - right), height: h * (1 - top - bottom))
                                .offset(x: w * left, y: h * top)
                        }.frame(width: geometry.size.width, height: geometry.size.height)
                    }.frame(height: 280).accessibilityLabel("Vorschau des Bildausschnitts")
                    edge("Links", value: $left, opposite: right)
                    edge("Rechts", value: $right, opposite: left)
                    edge("Oben", value: $top, opposite: bottom)
                    edge("Unten", value: $bottom, opposite: top)
                    Button("Ganzes Originalbild") { left = 0; right = 0; top = 0; bottom = 0 }
                    Text("Der helle Ausschnitt bleibt sichtbar. Das Original bleibt vollständig erhalten; der Zuschnitt lässt sich später erweitern.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }
            .navigationTitle("Bild zuschneiden").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anwenden") {
                        onApply(PageRect(x: left, y: top, width: 1 - left - right, height: 1 - top - bottom))
                        dismiss()
                    }
                }
            }
        }.preferredColorScheme(.dark)
    }

    private func edge(_ title: String, value: Binding<Double>, opposite: Double) -> some View {
        VStack(alignment: .leading) {
            Text("\(title) · \(Int((value.wrappedValue * 100).rounded())) %").font(.subheadline).monospacedDigit()
            Slider(value: value, in: 0...max(0, 0.98 - opposite)).accessibilityLabel("Zuschnitt \(title)")
        }
    }
}
