import Foundation
@preconcurrency import MetricKit
import NotebookCore

/// Apple's MetricKit: crash, hang, CPU, disk-write and launch diagnostics
/// with call stacks, delivered at the next launch, and daily figures
/// (launch time, hang time, scroll hitches, exits by reason, memory peak).
/// Turned into `DiagnosticReport`s with the history of the run they happened
/// in. MetricKit's JSON holds addresses and codes; exception messages are
/// removed before anything is stored (`DiagnosticPrivacy`).
final class DiagnosticsMetricKit: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = DiagnosticsMetricKit()
    private var subscribed = false

    func subscribe() {
        guard !subscribed else { return }
        subscribed = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        Diagnostics.queue.async { payloads.forEach(self.handle) }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        Diagnostics.queue.async { payloads.forEach(self.handle) }
    }

    // MARK: Diagnostics

    private func handle(_ payload: MXDiagnosticPayload) {
        let end = DiagnosticReport.milliseconds(payload.timeStampEnd)
        var all: [(MXDiagnostic, DiagnosticKind)] = []
        all += (payload.crashDiagnostics ?? []).map { ($0, .crash) }
        all += (payload.hangDiagnostics ?? []).map { ($0, .hang) }
        all += (payload.cpuExceptionDiagnostics ?? []).map { ($0, .cpu) }
        all += (payload.diskWriteExceptionDiagnostics ?? []).map { ($0, .diskWrite) }
        if #available(iOS 16.0, *) { all += (payload.appLaunchDiagnostics ?? []).map { ($0, .launch) } }
        for (diagnostic, kind) in all { report(diagnostic, kind: kind, fallbackTime: end) }
    }

    private func report(_ diagnostic: MXDiagnostic, kind: DiagnosticKind, fallbackTime: Int64) {
        var facts = DiagnosticReporter.MetricKitFacts(kind: kind)
        let json = diagnostic.jsonRepresentation()
        facts.payloadJSON = json
        facts.build = DiagnosticPrivacy.safeDetail(diagnostic.metaData.applicationBuildVersion)
        if let crash = diagnostic as? MXCrashDiagnostic {
            facts.exceptionType = crash.exceptionType?.intValue
            facts.exceptionCode = crash.exceptionCode?.intValue
            facts.signal = crash.signal?.intValue
            facts.terminationReason = crash.terminationReason.flatMap(DiagnosticPrivacy.safeDetail)
            facts.stackGuard = crash.virtualMemoryRegionInfo?.lowercased().contains("stack guard") ?? false
            if #available(iOS 17.0, *), let reason = crash.exceptionReason {
                // Type names only; the composed message can quote app data.
                facts.objcExceptionName = DiagnosticPrivacy.safeDetail(reason.exceptionName.isEmpty ? reason.className : reason.exceptionName)
            }
            facts.callStackJSON = crash.callStackTree.jsonRepresentation()
        } else if let hang = diagnostic as? MXHangDiagnostic {
            facts.durationMilliseconds = Int(hang.hangDuration.converted(to: .milliseconds).value)
            facts.callStackJSON = hang.callStackTree.jsonRepresentation()
        } else if let cpu = diagnostic as? MXCPUExceptionDiagnostic {
            facts.durationMilliseconds = Int(cpu.totalCPUTime.converted(to: .milliseconds).value)
            facts.callStackJSON = cpu.callStackTree.jsonRepresentation()
        } else if let disk = diagnostic as? MXDiskWriteExceptionDiagnostic {
            facts.callStackJSON = disk.callStackTree.jsonRepresentation()
            _ = disk.totalWritesCaused
        } else if #available(iOS 16.0, *), let launch = diagnostic as? MXAppLaunchDiagnostic {
            facts.durationMilliseconds = Int(launch.launchDuration.converted(to: .milliseconds).value)
            facts.callStackJSON = launch.callStackTree.jsonRepresentation()
        }
        // MetricKit has no own time per diagnostic: the payload's end, which
        // for crashes is close to the crash. The history of that run comes along.
        facts.occurredAt = fallbackTime
        let (session, crumbs) = Diagnostics.breadcrumbs(ofRunAt: fallbackTime)
        var report = Diagnostics.reporter.metricKit(facts, session: session, breadcrumbs: crumbs,
                                                    at: DiagnosticReport.milliseconds(Date()))
        // Same diagnostic delivered twice: same ID, the server answers 409.
        report.id = Self.stableID(json)
        Diagnostics.add(report)
    }

    static func stableID(_ data: Data) -> String {
        let c = Array(NotebookCore.SHA256.hexDigest(data).prefix(32))
        return "\(String(c[0..<8]))-\(String(c[8..<12]))-\(String(c[12..<16]))-\(String(c[16..<20]))-\(String(c[20..<32]))".uppercased()
    }

    // MARK: Daily figures

    private func handle(_ payload: MXMetricPayload) {
        var values: [String: String] = ["source": "metrickit",
                                        "from": String(DiagnosticReport.milliseconds(payload.timeStampBegin)),
                                        "to": String(DiagnosticReport.milliseconds(payload.timeStampEnd))]
        if let build = payload.metaData?.applicationBuildVersion { values["build"] = build }
        if let launch = payload.applicationLaunchMetrics {
            values["launchFirstDrawMsMean"] = Self.mean(launch.histogrammedTimeToFirstDraw).map(String.init)
            values["launchResumeMsMean"] = Self.mean(launch.histogrammedApplicationResumeTime).map(String.init)
        }
        if let responsiveness = payload.applicationResponsivenessMetrics {
            values["hangMsMean"] = Self.mean(responsiveness.histogrammedApplicationHangTime).map(String.init)
            values["hangCount"] = String(Self.count(responsiveness.histogrammedApplicationHangTime))
        }
        if let animation = payload.animationMetrics {
            values["scrollHitchMsPerS"] = String(format: "%.2f", animation.scrollHitchTimeRatio.value)
        }
        if let memory = payload.memoryMetrics {
            values["memoryPeakMB"] = String(Int(memory.peakMemoryUsage.converted(to: .megabytes).value))
        }
        if let cpu = payload.cpuMetrics {
            values["cpuSeconds"] = String(Int(cpu.cumulativeCPUTime.converted(to: .seconds).value))
        }
        var memoryExits = 0
        if let exits = payload.applicationExitMetrics {
            let foreground = exits.foregroundExitData, background = exits.backgroundExitData
            memoryExits = foreground.cumulativeMemoryResourceLimitExitCount + background.cumulativeMemoryResourceLimitExitCount
            values["exitForegroundNormal"] = String(foreground.cumulativeNormalAppExitCount)
            values["exitForegroundMemory"] = String(foreground.cumulativeMemoryResourceLimitExitCount)
            values["exitForegroundWatchdog"] = String(foreground.cumulativeAppWatchdogExitCount)
            values["exitForegroundBadAccess"] = String(foreground.cumulativeBadAccessExitCount)
            values["exitForegroundIllegalInstruction"] = String(foreground.cumulativeIllegalInstructionExitCount)
            values["exitForegroundAbnormal"] = String(foreground.cumulativeAbnormalExitCount)
            values["exitBackgroundMemory"] = String(background.cumulativeMemoryResourceLimitExitCount)
            values["exitBackgroundMemoryPressure"] = String(background.cumulativeMemoryPressureExitCount)
            values["exitBackgroundWatchdog"] = String(background.cumulativeAppWatchdogExitCount)
            values["exitBackgroundSuspendedLockedFile"] = String(background.cumulativeSuspendedWithLockedFileExitCount)
        }
        let now = DiagnosticReport.milliseconds(Date())
        let json = payload.jsonRepresentation()
        var report = Diagnostics.reporter.metrics(values.compactMapValues { $0 }, payloadJSON: json, at: now)
        report.id = Self.stableID(json)
        Diagnostics.add(report)
        if memoryExits > 0 {
            // Ended for memory: no stack from MetricKit, but worth its own entry.
            var memory = Diagnostics.reporter.metrics(["source": "metrickit", "memoryExits": String(memoryExits),
                                                       "build": values["build"] ?? "?"], payloadJSON: nil, at: now)
            memory.kind = .memory
            memory.summary = ""; memory.signature = ""
            memory = memory.finalized(appImage: Diagnostics.appImage)
            memory.summary = "Speicherlimit · \(memoryExits)× vom System wegen Speicherverbrauch beendet"
            Diagnostics.add(memory)
        }
    }

    private static func mean(_ histogram: MXHistogram<UnitDuration>) -> Int? {
        var total = 0.0, count = 0
        let enumerator = histogram.bucketEnumerator
        while let bucket = enumerator.nextObject() as? MXHistogramBucket<UnitDuration> {
            let start = bucket.bucketStart.converted(to: .milliseconds).value, end = bucket.bucketEnd.converted(to: .milliseconds).value
            total += (start + end) / 2 * Double(bucket.bucketCount)
            count += bucket.bucketCount
        }
        return count > 0 ? Int(total / Double(count)) : nil
    }

    private static func count<Unit>(_ histogram: MXHistogram<Unit>) -> Int {
        var count = 0
        let enumerator = histogram.bucketEnumerator
        while let bucket = enumerator.nextObject() as? MXHistogramBucket<Unit> { count += bucket.bucketCount }
        return count
    }
}
