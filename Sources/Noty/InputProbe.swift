import UIKit
import OSLog

/// Views that add their own state to an input report (`InputProbe`).
@MainActor
protocol InputProbeDescribing: AnyObject {
    var probeDescription: String { get }
}

/// Always-on diagnosis for a feedback pattern (Build 113): taps partly work,
/// but nothing can be dragged and the Pencil does not write, until the app
/// went to the background. Reports go to Documents/Diagnose/eingabe.txt
/// (Dateien › Auf meinem iPad › noty dev, or read over USB) and the system log:
/// - touches without effect: three drags or strokes within 30 s that nothing
///   reacted to and no recognizer took, with the recognizers and states each
///   touch reached, the views under it and the editor state;
/// - a touch sequence of the window open for over 20 s (a touch UIKit still
///   counts as down; also a resting hand);
/// - a lock held too long (`lock`): input paused for a backup commit, busy;
/// - leaving the app shortly after drags that nothing visibly reacted to.
/// Observes only: the touches come from `UserInputClock`'s observer, which
/// fails at once, and are read afterwards on a display link while they last.
/// Records class names, states, sizes and times, never content.
@MainActor
enum InputProbe {
    private static let log = Logger(subsystem: "de.la.noty", category: "input-probe")

    // MARK: Registered state

    /// Returns nil once its owner is gone (the entry is then dropped).
    typealias Provider = () -> String?
    /// Returns whether it is locked and a description, nil once its owner is gone.
    typealias Check = () -> (locked: Bool, text: String)?
    private struct Lock { var after: CFTimeInterval; var check: Check; var since: CFTimeInterval?; var reported = false }
    private static var providers: [String: Provider] = [:]
    private static var locks: [String: Lock] = [:]
    static func register(_ key: String, state: @escaping Provider) { providers[key] = state }
    /// Reported once per episode when `check` stays locked for `after` seconds of foreground time.
    static func lock(_ key: String, after: CFTimeInterval, check: @escaping Check) {
        locks[key] = Lock(after: after, check: check)
        startTimer()
    }

    // MARK: Touches

    private struct Seen {
        var name: String
        var enabled: Bool
        var states: [UIGestureRecognizer.State] = []
        var took: Bool { states.contains { $0 == .began || $0 == .changed || $0 == .ended } }
    }
    private struct Track {
        weak var touch: UITouch?
        weak var window: UIWindow?
        var type: UITouch.TouchType
        var start: CGPoint
        var last: CGPoint
        var travel: CGFloat = 0
        /// Largest distance from the start: a resting, jittering finger stays small.
        var reach: CGFloat = 0
        var began: CFTimeInterval
        var hit: String
        /// Something reacted without `noteEffect`: a control tracked (no
        /// recognizer), a scroll view dragged or zoomed, a tap or swipe ended.
        var reacted: Bool
        var seen: [ObjectIdentifier: Seen] = [:]
        var order: [ObjectIdentifier] = []
    }
    /// Observers that begin with every Pencil touch without acting on it.
    private static let passive: Set<String> = [
        "PencilHoldGesture", "RulerWatchGesture", "PageInteractionObserver", "TouchDownWatcher",
        "LaserTouchObserver", "PencilTouchObserver", "Observer",
    ]
    private static let gates = ["_UISystemGestureGate", "_UIRelationshipGestureRecognizer"]
    private static var tracks: [Track] = []
    private static weak var event: UIEvent?
    private static var link: CADisplayLink?
    private static let ticker = Ticker()
    private static var recent: [String] = []
    private static var dead: [CFTimeInterval] = []
    private static var lastDead: (point: CGPoint, window: UIWindow?)?
    private static var suspicious: (time: CFTimeInterval, point: CGPoint, window: UIWindow?)?
    private static var lastPoint: (point: CGPoint, window: UIWindow?)?
    private static var lastTouchReport: CFTimeInterval = -.infinity
    private static var lastLeaveReport: CFTimeInterval = -.infinity
    private static var lastSequenceReport: CFTimeInterval = -.infinity
    /// Time of the previous sample: a touch found in the event began by then at the latest.
    private static var lastTick = CACurrentMediaTime()
    private static var lastEffect: CFTimeInterval = -.infinity
    /// The window observer failed at this touch-down and waits for all touches to end.
    private static var sequenceSince: CFTimeInterval?
    private static var sequenceReported = false

    /// Something visibly reacted (PencilKit began a stroke, a selection or
    /// field moved, the viewport scrolled): touches open since then count as taken.
    static func noteEffect() { lastEffect = CACurrentMediaTime() }

    /// From `UserInputClock`'s window observer, before it fails.
    static func began(_ touches: Set<UITouch>, event: UIEvent, in window: UIWindow) {
        self.event = event
        if sequenceSince == nil { sequenceSince = CACurrentMediaTime() }
        startTimer()
        let now = CACurrentMediaTime()
        for touch in touches { track(touch, in: window, began: now) }
        lastTick = now
        startLink()
    }
    private static func startLink() {
        guard link == nil, !tracks.isEmpty else { return }
        let link = CADisplayLink(target: ticker, selector: #selector(Ticker.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    /// The observer is possible again: every touch of the sequence ended.
    static func observerReset() { sequenceSince = nil; sequenceReported = false }

    private static func track(_ touch: UITouch, in window: UIWindow, began: CFTimeInterval) {
        guard tracks.count < 8, !tracks.contains(where: { $0.touch === touch }) else { return }
        let point = touch.location(in: window)
        lastPoint = (point, window)
        tracks.append(Track(touch: touch, window: window, type: touch.type, start: point, last: point,
                            began: began, hit: chain(touch.view), reacted: touch.view is UIControl))
    }

    fileprivate static func sample() {
        // The observer sees only the first touch of a sequence; later ones
        // (a Pencil after a resting hand, a second finger) come from the event.
        let now = CACurrentMediaTime()
        for touch in event?.allTouches ?? [] where touch.phase != .ended && touch.phase != .cancelled {
            if let window = touch.window { track(touch, in: window, began: lastTick) }
        }
        lastTick = now
        var finished: [Track] = []
        tracks = tracks.compactMap { track in
            var track = track
            guard let touch = track.touch else { finished.append(track); return nil }
            if let window = track.window {
                let point = touch.location(in: window)
                track.travel += hypot(point.x - track.last.x, point.y - track.last.y); track.last = point
                track.reach = max(track.reach, hypot(point.x - track.start.x, point.y - track.start.y))
            }
            if (touch.view as? UIControl)?.isTracking == true { track.reacted = true }
            for recognizer in touch.gestureRecognizers ?? [] {
                if let scroll = recognizer.view as? UIScrollView, scroll.isDragging || scroll.isZooming { track.reacted = true }
                if recognizer.state == .ended, recognizer is UITapGestureRecognizer || recognizer is UISwipeGestureRecognizer { track.reacted = true }
                let id = ObjectIdentifier(recognizer)
                if track.seen[id] == nil {
                    track.order.append(id)
                    track.seen[id] = Seen(name: describe(recognizer), enabled: recognizer.isEnabled)
                }
                if track.seen[id]?.states.last != recognizer.state { track.seen[id]?.states.append(recognizer.state) }
            }
            if touch.phase == .ended || touch.phase == .cancelled { finished.append(track); return nil }
            // A touch UIKit no longer updates is closed after a minute (the sequence check reports it).
            if now - track.began > 60 { finished.append(track); return nil }
            return track
        }
        for track in finished { finish(track) }
        if tracks.isEmpty { link?.invalidate(); link = nil }
    }

    private static func finish(_ track: Track) {
        let now = CACurrentMediaTime()
        let seen = track.order.compactMap { track.seen[$0] }
        // System gates begin without the touch doing anything.
        let takers = seen.filter { seen in
            seen.took && !passive.contains(baseName(seen.name)) && !gates.contains { seen.name.hasPrefix($0) }
        }.map(\.name)
        let drag = track.reach >= 20
        // Slack: PencilKit may report its stroke before the window observer sees the touch.
        let reacted = lastEffect >= track.began - 0.1 || track.reacted
        let isDead = drag && !reacted && takers.isEmpty
        let verdict = !drag || reacted ? "" : isDead ? " OHNE WIRKUNG" : " ohne sichtbare Reaktion, genommen von \(takers.joined(separator: ", "))"
        let recognizers = seen.map { "\($0.name)\($0.enabled ? "" : "(aus)"):" + $0.states.map(stateName).joined(separator: ">") }
            .joined(separator: " ")
        let line = "\(clock()) \(typeName(track.type)) \(Int(track.reach))/\(Int(track.travel))pt \(String(format: "%.2f", now - track.began))s"
            + "\(verdict) an \(Int(track.start.x))/\(Int(track.start.y))\n    Treffer: \(track.hit)\n    Erkenner: \(recognizers)"
        recent.append(line)
        if recent.count > 40 { recent.removeFirst(recent.count - 40) }
        guard drag, !reacted else { return }
        suspicious = (now, track.start, track.window)
        guard isDead else { return }
        // Two fingers of one gesture count once.
        if dead.last != track.began { dead.append(track.began) }
        dead.removeAll { now - $0 > 30 }
        lastDead = (track.start, track.window)
        log.error("Touch without effect: \(line, privacy: .public)")
        guard dead.count >= 3, now - lastTouchReport > 120 else { return }
        lastTouchReport = now
        let count = dead.count, point = track.start, window = track.window
        // Not inside the touch-down that may have finished this track.
        Task { @MainActor in report("Berührungen ohne Wirkung (\(count) in 30 s)", at: point, in: window) }
    }

    // MARK: Timer: locks and open sequences

    private static var timer: Timer?
    private static func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { check() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        let center = NotificationCenter.default
        // Suspended time is no lock time.
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for key in locks.keys where locks[key]?.since != nil { locks[key]?.since = CACurrentMediaTime() }
            }
        }
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { leaving() }
        }
    }
    private static func check() {
        guard UIApplication.shared.applicationState == .active else { return }
        let now = CACurrentMediaTime()
        for key in Array(locks.keys) {
            guard var lock = locks[key] else { continue }
            guard let result = lock.check() else { locks[key] = nil; continue }
            if !result.locked {
                if lock.reported, let since = lock.since { write("\(clock()) Sperre \(key) gelöst nach \(Int(now - since)) s") }
                lock.since = nil; lock.reported = false
            } else {
                let since = lock.since ?? now
                lock.since = since
                if now - since >= lock.after, !lock.reported {
                    lock.reported = true
                    let at = lastDead ?? lastPoint
                    Task { @MainActor in report("Sperre \(key) seit \(Int(now - since)) s: \(result.text)", at: at?.point, in: at?.window) }
                }
            }
            locks[key] = lock
        }
        // A sequence of the window still open: the touches UIKit counts as
        // down are tracked again (also after the 60 s cutoff of a track).
        if sequenceSince != nil, link == nil {
            sample(); startLink()
        }
        // Reported only while nothing reacts (a resting hand while writing does not count).
        if let since = sequenceSince, now - since > 20, now - lastEffect > 20, !sequenceReported, now - lastSequenceReport > 600 {
            sequenceReported = true; lastSequenceReport = now
            let open = (event?.allTouches ?? []).map { touch in
                "\(typeName(touch.type)) \(phaseName(touch.phase)), letzte Änderung vor \(Int(now - touch.timestamp)) s, auf \(chain(touch.view))"
            }.joined(separator: "; ")
            report("Berührungsfolge seit \(Int(now - since)) s offen (auch eine aufliegende Hand): \(open.isEmpty ? "keine Berührung mehr im Ereignis" : open)",
                   at: lastPoint?.point, in: lastPoint?.window)
        }
    }
    /// Leaving the app was what freed it in the feedback: what came before.
    private static func leaving() {
        let now = CACurrentMediaTime()
        guard let suspicious, now - suspicious.time < 120, now - lastLeaveReport > 600 else { return }
        lastLeaveReport = now
        report("App verlassen nach Zügen ohne sichtbare Reaktion", at: suspicious.point, in: suspicious.window)
    }

    // MARK: Report

    private static func report(_ reason: String, at point: CGPoint?, in window: UIWindow?) {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var lines = ["", "=== \(Date().formatted(.iso8601)) Build \(build): \(reason)"]
        lines.append("App: \(stateName(UIApplication.shared.applicationState)), offene Berührungen \(tracks.count)")
        for key in providers.keys.sorted() {
            guard let text = providers[key]?() else { providers[key] = nil; continue }
            lines.append("\(key): \(text)")
        }
        if let window, let point {
            lines.append("Ansichten unter \(Int(point.x))/\(Int(point.y)) (vorn zuerst):")
            var budget = 160
            stack(window, at: point, depth: 0, into: &lines, budget: &budget)
        }
        lines.append("Letzte Berührungen:")
        lines.append(contentsOf: recent.suffix(25))
        let text = lines.joined(separator: "\n")
        log.error("\(text, privacy: .public)")
        write(text)
    }

    /// Front-most first: the views containing `point`, their own state and recognizers.
    private static func stack(_ view: UIView, at point: CGPoint, depth: Int, into lines: inout [String], budget: inout Int) {
        guard budget > 0, depth < 48, !view.isHidden, view.alpha > 0.01, view.bounds.contains(point) else { return }
        budget -= 1
        var text = String(repeating: " ", count: min(depth, 24)) + name(view)
        if !view.isUserInteractionEnabled { text += " ui=aus" }
        if view.alpha < 1 { text += " alpha=\(String(format: "%.2f", view.alpha))" }
        if let scroll = view as? UIScrollView {
            text += " scroll=\(scroll.isScrollEnabled ? "an" : "aus") zoom=\(String(format: "%.2f", scroll.zoomScale))"
            if scroll.isTracking || scroll.isDragging || scroll.isDecelerating { text += " bewegt" }
        }
        if view.isFirstResponder { text += " erster-responder" }
        let recognizers = (view.gestureRecognizers ?? []).map { name($0) + ($0.isEnabled ? "" : "(aus)") + ":" + stateName($0.state) }
        if !recognizers.isEmpty { text += " [" + recognizers.joined(separator: " ") + "]" }
        if let describing = view as? InputProbeDescribing { text += " {" + describing.probeDescription + "}" }
        lines.append(text)
        for child in view.subviews.reversed() {
            stack(child, at: view.convert(point, to: child), depth: depth + 1, into: &lines, budget: &budget)
        }
    }

    // MARK: Names

    /// Class name without generic arguments (SwiftUI hosts are long).
    private static func name(_ object: AnyObject) -> String {
        let full = String(describing: type(of: object))
        return String(full.prefix { $0 != "<" })
    }
    private static func describe(_ recognizer: UIGestureRecognizer) -> String {
        recognizer.view.map { name(recognizer) + "@" + name($0) } ?? name(recognizer)
    }
    private static func baseName(_ described: String) -> String {
        String(described.split(separator: "@", maxSplits: 1).first ?? "")
    }
    private static func chain(_ view: UIView?) -> String {
        var names: [String] = [], current = view
        while let item = current, names.count < 6 {
            names.append(name(item) + (item.isUserInteractionEnabled ? "" : "(ui=aus)"))
            current = item.superview
        }
        return names.isEmpty ? "keine Ansicht" : names.joined(separator: " < ")
    }
    private static func stateName(_ state: UIGestureRecognizer.State) -> String {
        switch state {
        case .possible: "möglich"
        case .began: "begonnen"
        case .changed: "geändert"
        case .ended: "beendet"
        case .cancelled: "abgebrochen"
        case .failed: "gescheitert"
        @unknown default: "?\(state.rawValue)"
        }
    }
    private static func stateName(_ state: UIApplication.State) -> String {
        switch state {
        case .active: "aktiv"
        case .inactive: "inaktiv"
        case .background: "Hintergrund"
        @unknown default: "?"
        }
    }
    private static func phaseName(_ phase: UITouch.Phase) -> String {
        switch phase {
        case .began: "begonnen"
        case .moved: "bewegt"
        case .stationary: "ruhend"
        case .ended: "beendet"
        case .cancelled: "abgebrochen"
        default: "?\(phase.rawValue)"
        }
    }
    private static func typeName(_ type: UITouch.TouchType) -> String {
        switch type {
        case .direct: "Finger"
        case .pencil: "Pencil"
        case .indirectPointer: "Zeiger"
        case .indirect: "indirekt"
        @unknown default: "?"
        }
    }
    private static func clock() -> String { Date().formatted(.dateTime.hour().minute().second()) }

    // MARK: File

    private static let fileQueue = DispatchQueue(label: "noty.input-probe.file", qos: .utility)
    private static func write(_ text: String) {
        fileQueue.async {
            guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Diagnose", isDirectory: true) else { return }
            let url = folder.appendingPathComponent("eingabe.txt")
            let data = Data((text + "\n").utf8)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            // Full: kept once as eingabe.1.txt, so the report that mattered survives later ones.
            if size >= 1_000_000 {
                let older = folder.appendingPathComponent("eingabe.1.txt")
                try? FileManager.default.removeItem(at: older)
                try? FileManager.default.moveItem(at: url, to: older)
            }
            guard size > 0, size < 1_000_000, let handle = try? FileHandle(forWritingTo: url) else {
                try? data.write(to: url, options: .atomic); return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private final class Ticker: NSObject {
        @objc func tick() { MainActor.assumeIsolated { InputProbe.sample() } }
    }
}
