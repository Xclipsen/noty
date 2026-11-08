import Foundation

/// Summary, grouping signature and known crash patterns of a report. The
/// same rules live in `scripts/diag_report.py` (with symbol names on top);
/// keep both in step.
public enum DiagnosticAnalysis {
    public enum Pattern: String, Sendable, CaseIterable {
        case stackOverflow, watchdog, swiftTrap, objcException, abort, badAccess, memoryLimit

        public var text: String {
            switch self {
            case .stackOverflow: "Stapelüberlauf (meist beim View-Aufbau: tief verschachtelte SwiftUI-Typen oder Rekursion)"
            case .watchdog: "Watchdog-Abbruch: der Hauptthread blockierte zu lange"
            case .swiftTrap: "Swift-Laufzeitfalle (fatalError, erzwungenes Entpacken, Index außerhalb, Überlauf)"
            case .objcException: "Objective-C-Ausnahme"
            case .abort: "Abbruch (SIGABRT)"
            case .badAccess: "Speicherzugriffsfehler"
            case .memoryLimit: "Vom System wegen Speicherverbrauch beendet"
            }
        }
    }

    /// German names of the measured operations (`DiagnosticThresholds`).
    public static func operationLabel(_ operation: String) -> String {
        switch operation {
        case "notebook.open": "Heft öffnen"
        case "page.switch": "Seite wechseln"
        case "save": "Speichern"
        case "stroke.commit": "Strich abschließen"
        case "law.window": "Gesetzesfenster"
        case "law.load": "Gesetz laden"
        case "search": "Suche"
        case "search.index": "Suchindex erfassen"
        case "pdf.export": "PDF-Export"
        case "backup": "Backup"
        case "appSync": "App-Abgleich (Abzug)"
        case "appSync.mirror": "App-Abgleich (Spiegel)"
        case "restore": "Wiederherstellen"
        default: operation
        }
    }

    public static func pattern(for report: DiagnosticReport) -> Pattern? {
        let details = report.details
        if report.kind == .memory { return .memoryLimit }
        if details["terminationReason"]?.lowercased().contains("8badf00d") == true { return .watchdog }
        guard report.kind == .crash || report.kind == .abnormalExit || report.kind == .test else { return nil }
        let signal = Int(details["signal"] ?? "")
        let exception = Int(details["exceptionType"] ?? "")
        if details["stackGuard"] == "1" || isRecursive(report.callStack) || Int(details["stackDepth"] ?? "") ?? 0 >= 512 {
            return .stackOverflow
        }
        if exception == 6 || signal == 5 { return .swiftTrap }
        if details["objcException"] != nil { return .objcException }
        if signal == 6 { return .abort }
        if exception == 1 || signal == 11 || signal == 10 { return .badAccess }
        return nil
    }

    /// One address on the stack 32 times or more: unbounded recursion.
    public static func isRecursive(_ stack: [DiagnosticFrame]) -> Bool {
        guard stack.count >= 64 else { return false }
        var counts: [DiagnosticFrame: Int] = [:]
        for frame in stack { counts[frame, default: 0] += 1 }
        return (counts.values.max() ?? 0) >= 32
    }

    public static func summary(for report: DiagnosticReport) -> String {
        let details = report.details
        var parts = [report.kind.label]
        switch report.kind {
        case .slow:
            let operation = details["operation"].map(operationLabel) ?? "Vorgang"
            parts = ["Langsam: \(operation) \(details["durationMs"] ?? "?") ms (Schwelle \(details["thresholdMs"] ?? "?") ms)"]
        case .hang, .appHang:
            if let ms = details["durationMs"] { parts.append("\(ms) ms") }
        case .failure:
            let operation = details["operation"].map(operationLabel) ?? "Vorgang"
            parts = ["\(operation) fehlgeschlagen" + (details["errorCode"].map { " (\(details["errorDomain"] ?? "Fehler") \($0))" } ?? "")]
        case .abnormalExit:
            parts.append("in Phase \(report.launchPhase ?? "?")")
        default:
            if let type = details["exceptionName"] ?? details["exceptionTypeName"] { parts.append(type) }
            if let signal = details["signalName"] { parts.append(signal) }
        }
        if let pattern = pattern(for: report) { parts.append(pattern.text) }
        if let frame = firstAppFrame(report.callStack) { parts.append("bei \(frame.label)") }
        return parts.joined(separator: " · ")
    }

    /// Groups equal causes within one build: kind, pattern or operation, and
    /// the innermost three frames of the app (all frames if none is the app's).
    public static func signature(for report: DiagnosticReport, appImage: String = "Noty") -> String {
        var head = report.kind.rawValue
        if let operation = report.details["operation"] { head += ":" + operation }
        if let pattern = pattern(for: report) { head += ":" + pattern.rawValue }
        let appFrames = report.callStack.filter { $0.image == appImage }
        let frames = (appFrames.isEmpty ? report.callStack : appFrames).prefix(3)
        guard !frames.isEmpty else { return head }
        return head + "|" + frames.map(\.label).joined(separator: ">")
    }

    public static func firstAppFrame(_ stack: [DiagnosticFrame], appImage: String = "Noty") -> DiagnosticFrame? {
        stack.first { $0.image == appImage }
    }
}

/// MetricKit's call stack trees (`MXCallStackTree.jsonRepresentation()`),
/// parsed without MetricKit so the rules are testable on Linux.
public enum MetricKitCallStack {
    public struct Thread: Equatable, Sendable {
        public var attributed: Bool
        /// Innermost frame first.
        public var frames: [DiagnosticFrame]
    }

    /// Every thread; for aggregated trees (CPU, disk writes) the heaviest path.
    public static func threads(fromJSON data: Data) -> [Thread] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let tree = (object["callStackTree"] as? [String: Any]) ?? object
        let stacks = tree["callStacks"] as? [[String: Any]] ?? []
        return stacks.map { stack in
            let roots = stack["callStackRootFrames"] as? [[String: Any]] ?? []
            var frames: [DiagnosticFrame] = []
            var level = heaviest(roots)
            while let frame = level, frames.count < 2_048 {
                frames.append(DiagnosticFrame(image: frame["binaryName"] as? String ?? "?",
                                              offset: number(frame["offsetIntoBinaryTextSegment"]),
                                              uuid: frame["binaryUUID"] as? String))
                level = heaviest(frame["subFrames"] as? [[String: Any]] ?? [])
            }
            return Thread(attributed: stack["threadAttributed"] as? Bool ?? false, frames: frames)
        }
    }

    /// The crashed or hung thread: the attributed one, else the first.
    public static func mainStack(fromJSON data: Data) -> [DiagnosticFrame] {
        let all = threads(fromJSON: data)
        return (all.first { $0.attributed } ?? all.first)?.frames ?? []
    }

    private static func heaviest(_ frames: [[String: Any]]) -> [String: Any]? {
        frames.max { number($0["sampleCount"]) < number($1["sampleCount"]) }
    }

    private static func number(_ value: Any?) -> UInt64 {
        if let value = value as? UInt64 { return value }
        if let value = value as? Int { return UInt64(max(value, 0)) }
        if let value = value as? Double { return UInt64(max(value, 0)) }
        if let value = value as? NSNumber { return value.uint64Value }
        return 0
    }
}
