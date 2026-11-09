import Foundation

// Einheitliche Fehler- und Ruckler-Diagnose (docs/DIAGNOSE.md).
//
// One fixed report form for crashes, hangs, slow operations and failures from
// every channel. A report carries only build data, system codes, code
// addresses (image + offset) and the breadcrumbs of `DiagnosticJournal`:
// fixed event names and integers, never titles, texts, paths or law content.
// The server (`diagnostics/server.py`) and `scripts/diag_report.py` read the
// same JSON; change all three together and raise `formatVersion` on a break.

/// What happened. Raw values are the wire format.
public enum DiagnosticKind: String, Codable, CaseIterable, Sendable {
    /// MetricKit: the app crashed (delivered at the next launch).
    case crash
    /// MetricKit: the system recorded a main-thread hang.
    case hang
    /// Own watchdog (`HangProbe`): main thread stalled for 2 s or more.
    case appHang
    /// MetricKit: CPU exception (too much CPU over time).
    case cpu
    /// MetricKit metrics: the app was ended for its memory use.
    case memory
    /// MetricKit: too many disk writes.
    case diskWrite
    /// MetricKit: slow launch.
    case launch
    /// A measured operation took longer than its threshold.
    case slow
    /// Saving, backup, restore or app sync failed.
    case failure
    /// The previous run ended in the foreground without a clean exit.
    case abnormalExit
    /// Daily MetricKit figures (launch time, hitch rate, hang time, exits).
    case metrics
    /// The hidden test menu of the test apps.
    case test

    /// Plain German label for lists.
    public var label: String {
        switch self {
        case .crash: "Absturz"
        case .hang: "Hänger (System)"
        case .appHang: "Hänger"
        case .cpu: "CPU-Last"
        case .memory: "Speicherlimit"
        case .diskWrite: "Schreiblast"
        case .launch: "Langsamer Start"
        case .slow: "Langsam"
        case .failure: "Fehler"
        case .abnormalExit: "Unerwartet beendet"
        case .metrics: "Tageswerte"
        case .test: "Test"
        }
    }
}

public struct DiagnosticAppInfo: Codable, Equatable, Sendable {
    /// stable, dev, ai or calendar (Info.plist `NotyChannel`).
    public var channel: String
    public var bundleID: String
    public var version: String
    public var build: String
    /// Short commit hash written by publish_ota.sh; empty for local builds.
    public var commit: String

    public init(channel: String, bundleID: String, version: String, build: String, commit: String) {
        self.channel = channel; self.bundleID = bundleID; self.version = version; self.build = build; self.commit = commit
    }
}

public struct DiagnosticDeviceInfo: Codable, Equatable, Sendable {
    /// Hardware model such as iPad16,3; no name, no identifier.
    public var model: String
    public var os: String

    public init(model: String, os: String) { self.model = model; self.os = os }
}

/// One return address: image name and offset into its text segment.
public struct DiagnosticFrame: Codable, Equatable, Hashable, Sendable {
    public var image: String
    public var offset: UInt64
    /// Mach-O UUID of the image when known (MetricKit, dyld).
    public var uuid: String?

    public init(image: String, offset: UInt64, uuid: String? = nil) {
        self.image = image; self.offset = offset; self.uuid = uuid
    }

    public var label: String { "\(image)+0x\(String(offset, radix: 16))" }
}

public struct DiagnosticReport: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    /// Upper bound the server accepts per report.
    public static let maximumEncodedSize = 1_000_000

    public var formatVersion: Int
    public var id: String
    public var kind: DiagnosticKind
    /// When the report was written (milliseconds since 1970).
    public var createdAt: Int64
    /// When the problem happened, if known (MetricKit end time, event time).
    public var occurredAt: Int64?
    public var app: DiagnosticAppInfo
    public var device: DiagnosticDeviceInfo
    /// The run it happened in (`DiagnosticSessionLog`).
    public var launchID: String?
    /// Last launch phase reached in that run (library, notebook, lawWindow, running …).
    public var launchPhase: String?
    /// Plain German one-liner, built from fixed words and numbers.
    public var summary: String
    /// Groups equal causes within one build (`DiagnosticAnalysis.signature`).
    public var signature: String
    /// Fixed keys, system codes and numbers only (`DiagnosticPrivacy.safeDetail`).
    public var details: [String: String]
    /// The crashed, hung or sampled thread, innermost frame first.
    public var callStack: [DiagnosticFrame]
    public var breadcrumbs: [DiagnosticBreadcrumb]
    /// MetricKit's own JSON with message texts removed: addresses only.
    public var payload: String?

    public init(id: String = UUID().uuidString, kind: DiagnosticKind, createdAt: Int64, occurredAt: Int64? = nil,
                app: DiagnosticAppInfo, device: DiagnosticDeviceInfo, launchID: String? = nil, launchPhase: String? = nil,
                summary: String = "", signature: String = "", details: [String: String] = [:],
                callStack: [DiagnosticFrame] = [], breadcrumbs: [DiagnosticBreadcrumb] = [], payload: String? = nil) {
        self.formatVersion = Self.currentFormatVersion
        self.id = id; self.kind = kind; self.createdAt = createdAt; self.occurredAt = occurredAt
        self.app = app; self.device = device; self.launchID = launchID; self.launchPhase = launchPhase
        self.summary = summary; self.signature = signature; self.details = details
        self.callStack = callStack; self.breadcrumbs = breadcrumbs; self.payload = payload
    }

    /// Fills summary and signature from kind, details and stack, drops unsafe
    /// detail values, and trims payload and stack so the report stays under
    /// the server's limit.
    public func finalized(appImage: String = "Noty") -> DiagnosticReport {
        var report = self
        report.details = DiagnosticPrivacy.sanitized(details: details)
        report.breadcrumbs = DiagnosticPrivacy.sanitized(breadcrumbs: breadcrumbs)
        if report.callStack.count > 512 {
            // Deep recursion: the innermost frames and the outermost tell the story.
            report.details["stackDepth"] = String(report.callStack.count)
            report.callStack = Array(report.callStack.prefix(384)) + Array(report.callStack.suffix(64))
        }
        if report.summary.isEmpty { report.summary = DiagnosticAnalysis.summary(for: report) }
        if report.signature.isEmpty { report.signature = DiagnosticAnalysis.signature(for: report, appImage: appImage) }
        if let payload = report.payload, payload.utf8.count > 600_000 { report.payload = nil; report.details["payloadDropped"] = "1" }
        return report
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> DiagnosticReport {
        let report = try JSONDecoder().decode(DiagnosticReport.self, from: data)
        guard report.formatVersion == currentFormatVersion else { throw DiagnosticFormatError.unsupportedVersion(report.formatVersion) }
        return report
    }
}

public enum DiagnosticFormatError: Error, Equatable {
    case unsupportedVersion(Int)
}

public extension DiagnosticReport {
    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
}
