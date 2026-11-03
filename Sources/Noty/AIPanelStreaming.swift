import SwiftUI
import UIKit
import NotebookCore

// Growing answers in the AI panel: the even reveal and the conversation that
// follows it. Display only; see AIStreaming.swift in Core for the rules.

/// Reveal of one growing answer. A class: the ticks of its row move it on
/// without SwiftUI state, so nothing but that row is drawn again.
@MainActor
final class AIRevealState {
    private var pacer: AIRevealPacer
    private var last: (count: Int, text: String) = (0, "")

    init(text: String) {
        pacer = AIRevealPacer(text: text, at: Self.now)
    }

    static var now: Double { Date().timeIntervalSinceReferenceDate }

    func receive(_ text: String) { pacer.receive(text, at: Self.now) }
    var caughtUp: Bool { pacer.caughtUp }

    /// The part to show at `time`; without animation everything that is safe.
    func text(at time: Double, animated: Bool) -> String {
        let count = animated ? pacer.advance(to: time, complete: false) : pacer.revealAll(at: time)
        if count != last.count { last = (count, pacer.shownText) }
        return last.text
    }
}

/// The answer being written: only this row redraws with the ticks, at most
/// 30 times a second and only while text is still to be shown. Finished
/// blocks come from the cache; only the open block is rendered again.
struct AIGrowingAnswer: View {
    let message: AIMessage
    let pages: [Int: UUID]
    let reveal: AIRevealState
    let render: (String) -> [AIRenderedBlock]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = reveal.receive(message.text)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || reveal.caughtUp)) { context in
            let text = reveal.text(at: context.date.timeIntervalSinceReferenceDate, animated: !reduceMotion)
            AIAnswerBlocks(key: AIAnswerBlocks.Key(message: message.id, length: text.utf8.count, pages: pages.count),
                           blocks: render(text), pages: pages)
                .equatable()
        }
    }
}

/// Blocks of an answer; equal as long as the shown text is, without
/// comparing attributed strings on every tick.
struct AIAnswerBlocks: View, Equatable {
    struct Key: Equatable { let message: String; let length: Int; let pages: Int }
    let key: Key
    let blocks: [AIRenderedBlock]
    let pages: [Int: UUID]

    nonisolated static func == (a: AIAnswerBlocks, b: AIAnswerBlocks) -> Bool { a.key == b.key && a.pages == b.pages }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in AIBlockView(block: block) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Following the answer

/// Moves the conversation with a growing answer while the user is at the
/// bottom, and leaves it alone once they scroll up (`AIScrollFollow`).
///
/// iOS 17 has no scroll geometry or phase in SwiftUI (`onScrollGeometryChange`,
/// `ScrollPosition`, `onScrollPhaseChange` are iOS 18). The controller
/// therefore reads the `UIScrollView` behind the SwiftUI `ScrollView` through
/// `AIScrollProbe`: KVO on offset and size, user scrolling from
/// `isTracking`/`isDragging`/`isDecelerating`. Growing content does not move
/// `contentOffset`, so the reading position stays put by itself; only the
/// controller moves it, and only while following. Without a scroll view the
/// panel falls back to `ScrollViewReader` (follows always, as before).
@MainActor
final class AIScrollController: NSObject, ObservableObject {
    @Published private(set) var showsJump = false
    private(set) var follow = AIScrollFollow()
    private weak var scrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var link: CADisplayLink?
    private var lastStep: CFTimeInterval = 0
    private var lastHeight: CGFloat = 0
    var reduceMotion = false
    var attached: Bool { scrollView != nil }

    func attach(_ view: UIScrollView) {
        guard view !== scrollView else { return }
        observations = []
        scrollView = view
        lastHeight = view.bounds.height
        observations = [
            view.observe(\.contentOffset, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.offsetChanged(view) }
            },
            view.observe(\.contentSize, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.sizeChanged(view) }
            },
            // Keyboard or panel size; bounds also move with every scroll, hence the height check.
            view.observe(\.bounds, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.boundsChanged(view) }
            },
        ]
        if follow.followsGrowth { moveToBottom(animated: false) }
    }

    func detach(_ view: UIScrollView?) {
        guard let view, view === scrollView else { return }
        observations = []; scrollView = nil
        stopLink()
    }

    /// „Nach unten“ and an own question glide down; another chat jumps.
    func followAgain(animated: Bool) {
        follow.follow()
        updateJump()
        moveToBottom(animated: animated)
    }

    private func distance(_ view: UIScrollView) -> CGFloat { bottomOffset(view) - view.contentOffset.y }
    private func bottomOffset(_ view: UIScrollView) -> CGFloat {
        max(-view.adjustedContentInset.top, view.contentSize.height + view.adjustedContentInset.bottom - view.bounds.height)
    }
    private func userScrolling(_ view: UIScrollView) -> Bool { view.isTracking || view.isDragging || view.isDecelerating }

    private func offsetChanged(_ view: UIScrollView) {
        if userScrolling(view) {
            stopLink()
            follow.userScrolled(distanceFromBottom: Double(distance(view)))
        }
        updateJump()
    }

    private func sizeChanged(_ view: UIScrollView) {
        updateJump()
        guard follow.followsGrowth, !userScrolling(view) else { return }
        // Far away (first layout, another chat): no long glide through the chat.
        moveToBottom(animated: distance(view) < view.bounds.height)
    }

    private func boundsChanged(_ view: UIScrollView) {
        guard abs(view.bounds.height - lastHeight) > 0.5 else { return }
        lastHeight = view.bounds.height
        sizeChanged(view)
    }

    private func updateJump() {
        let shows = scrollView.map { follow.showsJumpButton(distanceFromBottom: Double(distance($0))) } ?? false
        if shows != showsJump { showsJump = shows }
    }

    private func moveToBottom(animated: Bool) {
        guard let view = scrollView else { return }
        if !animated || reduceMotion {
            stopLink()
            view.setContentOffset(CGPoint(x: view.contentOffset.x, y: bottomOffset(view)), animated: false)
            return
        }
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastStep = CACurrentMediaTime()
    }

    /// A soft glide that keeps up with growing text: each frame covers a share
    /// of the way that only depends on time, not on the frame rate.
    @objc private func step(_ link: CADisplayLink) {
        guard let view = scrollView, follow.followsGrowth, !userScrolling(view) else { stopLink(); return }
        let now = link.timestamp
        let dt = min(max(now - lastStep, 1.0 / 120), 1.0 / 20)
        lastStep = now
        let target = bottomOffset(view), current = view.contentOffset.y
        let gap = target - current
        if abs(gap) < 0.5 {
            view.setContentOffset(CGPoint(x: view.contentOffset.x, y: target), animated: false)
            stopLink(); return
        }
        let share = 1 - exp(-dt / 0.12)
        view.setContentOffset(CGPoint(x: view.contentOffset.x, y: current + gap * share), animated: false)
    }

    private func stopLink() { link?.invalidate(); link = nil }
}

/// Finds the `UIScrollView` behind the SwiftUI `ScrollView` it sits in.
/// Placed as background of the scroll content, so the nearest scroll view
/// above it is that one (code blocks have their own, but beside it).
struct AIScrollProbe: UIViewRepresentable {
    let controller: AIScrollController

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.controller = controller
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: ProbeView, context: Context) {
        view.controller = controller
        view.connect()
    }

    final class ProbeView: UIView {
        weak var controller: AIScrollController?
        private weak var connected: UIScrollView?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { controller?.detach(connected); connected = nil } else { connect() }
        }
        func connect() {
            guard window != nil else { return }
            var parent = superview
            while let view = parent, !(view is UIScrollView) { parent = view.superview }
            guard let scroll = parent as? UIScrollView else { return }
            connected = scroll
            controller?.attach(scroll)
        }
    }
}

/// „Nach unten“, only while the user reads further up.
struct AIJumpPill: View {
    @ObservedObject var controller: AIScrollController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if controller.showsJump {
                Button { controller.followAgain(animated: true) } label: {
                    Label("Nach unten", systemImage: "arrow.down")
                        .font(.footnote.weight(.semibold)).foregroundStyle(.primary)
                        .padding(.horizontal, 14).frame(height: 32)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.secondary.opacity(0.25)))
                        .frame(minHeight: 44).contentShape(Capsule())
                }
                .buttonStyle(NotyPressStyle())
                .accessibilityHint("Folgt der Antwort wieder")
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(NotyMotion.highlight(reduceMotion), value: controller.showsJump)
        .padding(.bottom, 8)
    }
}
