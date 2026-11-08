import Foundation

/// Builds the reports of one run. The app passes only typed values: an
/// operation name (literal), durations, an `Error` (of which only domain and
/// code are kept, never its description or user info), MetricKit's numeric
/// codes and call stack JSON. Platform independent and tested on Linux.
public struct DiagnosticReporter: Sendable {
    public var app: DiagnosticAppInfo
    public var device: DiagnosticDeviceInfo
    public var launchID: String
    public var appImage: String

    public init(app: DiagnosticAppInfo, device: DiagnosticDeviceInfo, launchID: String, appImage: String = "Noty") {
        self.app = app; self.device = device; self.launchID = launchID; self.appImage = appImage
    }

    private func make(_ kind: DiagnosticKind, at time: Int64, occurredAt: Int64? = nil, launchID: String? = nil, phase: String?,
                      details: [String: String] = [:], stack: [DiagnosticFrame] = [], breadcrumbs: [DiagnosticBreadcrumb],
                      payload: String? = nil) -> DiagnosticReport {
        DiagnosticReport(kind: kind, createdAt: time, occurredAt: occurredAt ?? time, app: app, device: device,
                         launchID: launchID ?? self.launchID, launchPhase: phase, details: details, callStack: stack,
                         breadcrumbs: breadcrumbs, payload: payload).finalized(appImage: appImage)
    }

    public func slow(_ operation: DiagnosticEvent, milliseconds: Int, threshold: Int, values: [String: Int] = [:],
                     phase: String?, breadcrumbs: [DiagnosticBreadcrumb], at time: Int64) -> DiagnosticReport {
        var details = ["operation": operation.name, "durationMs": String(milliseconds), "thresholdMs": String(threshold)]
        for (key, value) in values { details[key] = String(value) }
        return make(.slow, at: time, phase: phase, details: details, breadcrumbs: breadcrumbs)
    }

    /// Only the error's domain and code: an error's text or user info can
    /// carry a title or a path.
    public func failure(_ operation: DiagnosticEvent, error: Error, phase: String?,
                        breadcrumbs: [DiagnosticBreadcrumb], at time: Int64) -> DiagnosticReport {
        let code = Self.errorCode(error)
        return make(.failure, at: time, phase: phase,
                    details: ["operation": operation.name, "errorDomain": code.domain, "errorCode": String(code.code)],
                    breadcrumbs: breadcrumbs)
    }

    public static func errorCode(_ error: Error) -> (domain: String, code: Int) {
        let ns = error as NSError
        // Swift errors bridge to their type name as the domain: a type, not data.
        let domain = DiagnosticPrivacy.safeDetail(ns.domain).flatMap { $0.contains(" ") ? nil : $0 } ?? "unbekannt"
        return (domain, ns.code)
    }

    /// Own watchdog: the main thread's sampled stack after `milliseconds`.
    public func appHang(milliseconds: Int, stack: [DiagnosticFrame], phase: String?,
                        breadcrumbs: [DiagnosticBreadcrumb], at time: Int64, test: Bool = false) -> DiagnosticReport {
        var details = ["durationMs": String(milliseconds)]
        if test { details["test"] = "1" }
        return make(.appHang, at: time, phase: phase, details: details, stack: stack, breadcrumbs: breadcrumbs)
    }

    public func abnormalExit(_ session: DiagnosticSessionLog.Session, breadcrumbs: [DiagnosticBreadcrumb], at time: Int64) -> DiagnosticReport {
        var report = make(.abnormalExit, at: time, occurredAt: breadcrumbs.last?.t ?? session.updatedAt, launchID: session.launchID,
                          phase: session.phase, details: ["state": session.state.rawValue, "build": session.build],
                          breadcrumbs: breadcrumbs)
        // The run's own build, which may be older than the one reporting.
        report.details["reportingBuild"] = app.build
        return report
    }

    /// Numbers from a MetricKit diagnostic (`MXDiagnostic` subclasses).
    public struct MetricKitFacts: Sendable {
        public var kind: DiagnosticKind
        public var occurredAt: Int64?
        /// The build MetricKit says the diagnostic belongs to.
        public var build: String?
        public var exceptionType: Int?
        public var exceptionCode: Int?
        public var signal: Int?
        public var terminationReason: String?
        public var objcExceptionName: String?
        public var stackGuard = false
        public var durationMilliseconds: Int?
        public var callStackJSON: Data?
        public var payloadJSON: Data?

        public init(kind: DiagnosticKind) { self.kind = kind }
    }

    public func metricKit(_ facts: MetricKitFacts, session: DiagnosticSessionLog.Session?, breadcrumbs: [DiagnosticBreadcrumb],
                          at time: Int64) -> DiagnosticReport {
        var details: [String: String] = ["source": "metrickit"]
        if let value = facts.exceptionType { details["exceptionType"] = String(value); details["exceptionTypeName"] = Self.exceptionName(value) }
        if let value = facts.exceptionCode { details["exceptionCode"] = String(value) }
        if let value = facts.signal { details["signal"] = String(value); details["signalName"] = Self.signalName(value) }
        if let value = facts.terminationReason { details["terminationReason"] = value }
        if let value = facts.objcExceptionName { details["objcException"] = value; details["exceptionName"] = value }
        if facts.stackGuard { details["stackGuard"] = "1" }
        if let value = facts.durationMilliseconds { details["durationMs"] = String(value) }
        if let build = facts.build { details["build"] = build }
        let stack = facts.callStackJSON.map(MetricKitCallStack.mainStack(fromJSON:)) ?? []
        let payload = facts.payloadJSON.flatMap(DiagnosticPrivacy.strippedMetricKitJSON)
        return make(facts.kind, at: time, occurredAt: facts.occurredAt, launchID: session?.launchID, phase: session?.phase,
                    details: details, stack: stack, breadcrumbs: breadcrumbs, payload: payload)
    }

    /// Daily figures; `values` are MetricKit's numbers under fixed keys.
    public func metrics(_ values: [String: String], payloadJSON: Data?, at time: Int64) -> DiagnosticReport {
        make(.metrics, at: time, phase: nil, details: values, breadcrumbs: [],
             payload: payloadJSON.flatMap(DiagnosticPrivacy.strippedMetricKitJSON))
    }

    public func test(_ event: DiagnosticEvent, phase: String?, breadcrumbs: [DiagnosticBreadcrumb], at time: Int64) -> DiagnosticReport {
        make(.test, at: time, phase: phase, details: ["test": event.name], breadcrumbs: breadcrumbs)
    }

    public static func exceptionName(_ type: Int) -> String {
        switch type {
        case 1: "EXC_BAD_ACCESS"
        case 2: "EXC_BAD_INSTRUCTION"
        case 3: "EXC_ARITHMETIC"
        case 5: "EXC_SOFTWARE"
        case 6: "EXC_BREAKPOINT"
        case 10: "EXC_CRASH"
        case 11: "EXC_RESOURCE"
        case 12: "EXC_GUARD"
        default: "EXC_\(type)"
        }
    }

    public static func signalName(_ signal: Int) -> String {
        switch signal {
        case 4: "SIGILL"
        case 5: "SIGTRAP"
        case 6: "SIGABRT"
        case 8: "SIGFPE"
        case 9: "SIGKILL"
        case 10: "SIGBUS"
        case 11: "SIGSEGV"
        case 13: "SIGPIPE"
        default: "SIG\(signal)"
        }
    }
}
