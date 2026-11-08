import Foundation
import NotebookCore

public struct RegistrationInput: Sendable {
    public var deviceToken: String
    public var environment: APNsEnvironment
    public var bundleID: String
    public var connectionID: UUID
    /// Device time zone: poll schedule and quiet hours.
    public var timeZone: String
    public var settings: DeviceSettings
    public var setup: WebUntisSetup
    /// Time zone of the connection: lesson times, days, change texts.
    public var connectionTimeZone: String
    public init(deviceToken: String, environment: APNsEnvironment, bundleID: String, connectionID: UUID, timeZone: String,
                settings: DeviceSettings, setup: WebUntisSetup, connectionTimeZone: String = CalendarDefaults.timeZoneIdentifier) {
        self.deviceToken = deviceToken; self.environment = environment; self.bundleID = bundleID; self.connectionID = connectionID
        self.timeZone = timeZone; self.settings = settings; self.setup = setup; self.connectionTimeZone = connectionTimeZone
    }
}

public struct UpdateInput: Sendable {
    public var deviceToken: String?
    public var environment: APNsEnvironment?
    public var bundleID: String?
    public var connectionID: UUID?
    public var timeZone: String?
    public var settings: DeviceSettings?
    public var setup: WebUntisSetup?
    public var connectionTimeZone: String?
    public init(deviceToken: String? = nil, environment: APNsEnvironment? = nil, bundleID: String? = nil, connectionID: UUID? = nil,
                timeZone: String? = nil, settings: DeviceSettings? = nil, setup: WebUntisSetup? = nil, connectionTimeZone: String? = nil) {
        self.deviceToken = deviceToken; self.environment = environment; self.bundleID = bundleID; self.connectionID = connectionID
        self.timeZone = timeZone; self.settings = settings; self.setup = setup; self.connectionTimeZone = connectionTimeZone
    }
}

public enum ServiceError: Error, Equatable {
    case limitReached
    case notFound
    /// The test request with the (new) Freigabe failed.
    case untis(PollFailure)
    /// The Freigabe names a server outside `allowedUntisHostSuffixes`.
    case serverNotAllowed
    case storage(String)
}

/// What the app may see about its registration (no secrets).
public struct DeviceStatus: Codable, Equatable, Sendable {
    public var deviceID: String
    public var state: DeviceState
    public var environment: APNsEnvironment
    public var connectionID: UUID
    public var lastPoll: Date?
    public var lastSuccess: Date?
    public var nextPoll: Date
    public var lastError: String?
    public var baselineAt: Date?
}

/// The service: registrations, polling, change detection and pushes. One
/// actor in one process is the only writer of the device files.
public actor PushService {
    public static let maximumSinglePushes = 3
    static let maximumSendAttempts = 3
    /// „Untis-Zugang prüfen“ (`kind: auth`; also shown by `noty-push demo-push`).
    public static let authTitle = "Untis-Zugang prüfen"
    public static let authBody = "Der Stundenplan kann nicht mehr abgerufen werden. Bitte in noty calendar die WebUntis-Freigabe neu verbinden."
    /// An authenticated request is written to the device file at most this often.
    static let contactPrecision: TimeInterval = 3600

    let config: PushConfig
    let store: DeviceStore
    let source: TimetableSource
    let sender: PushSender
    let detector: TimetableChangeDetecting
    let now: @Sendable () -> Date
    private(set) var records: [String: DeviceRecord] = [:]
    private var busy = Set<String>()
    private var lastMaintenance: Date?
    /// After an APNs „try later“, the device waits before the next attempt.
    private var retryAfter: [String: Date] = [:]
    /// APNs refused the service itself (key, team, topic): nothing is sent
    /// to any device before this time; the pause doubles (10 min … 3 h).
    private var providerRetryAt: Date?
    private var providerFailures = 0

    public init(config: PushConfig, store: DeviceStore, source: TimetableSource, sender: PushSender,
                detector: TimetableChangeDetecting = CoreChangeDetector(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config; self.store = store; self.source = source; self.sender = sender; self.detector = detector; self.now = now
        store.removeTemporaryFiles()
        let loaded = store.loadAll()
        for problem in loaded.problems { Log.error("Gerätedatei unlesbar, bleibt liegen: \(problem)") }
        for record in loaded.records { records[record.id] = record }
        Log.info("\(records.count) Gerät(e) geladen")
    }

    public var deviceCount: Int { records.count }
    public func record(_ id: String) -> DeviceRecord? { records[id] }

    // MARK: API

    public func authenticate(id: String, secret: String) -> Bool {
        guard let record = records[id] else {
            _ = Secrets.equal(Secrets.hash(secret), String(repeating: "0", count: 64))  // same work for unknown ids
            return false
        }
        return Secrets.equal(Secrets.hash(secret), record.secretHash)
    }

    /// An authenticated request of the app: remembered (hour precision) for
    /// the deletion of devices without contact (`noContactRetentionDays`).
    public func recordContact(id: String) {
        guard var record = records[id] else { return }
        let time = now()
        if let last = record.lastContact, last <= time, time.timeIntervalSince(last) < Self.contactPrecision { return }
        record.lastContact = time
        do { try persist(record) } catch { Log.error("Kontakt nicht gespeichert \(Log.device(id)): \(error)") }
    }

    public func register(_ input: RegistrationInput) async throws -> (deviceID: String, secret: String, status: DeviceStatus) {
        guard config.allowsUntisServer(input.setup.server) else { throw ServiceError.serverNotAllowed }
        func others() -> Int { records.values.filter { !($0.deviceToken == input.deviceToken && $0.bundleID == input.bundleID) }.count }
        guard others() < config.maxDevices else { throw ServiceError.limitReached }
        let started = now()
        let snapshot = try await baseline(setup: input.setup, connection: input.connectionID, connectionTimeZone: input.connectionTimeZone,
                                          at: started)
        guard others() < config.maxDevices else { throw ServiceError.limitReached }  // re-check after the await
        let id = UUID().uuidString.lowercased()
        let secret = Secrets.deviceSecret()
        let time = now()
        var record = DeviceRecord(id: id, secretHash: Secrets.hash(secret), created: time, updated: time, deviceToken: input.deviceToken,
                                  environment: input.environment, bundleID: input.bundleID, connectionID: input.connectionID,
                                  timeZone: input.timeZone, settings: input.settings, setup: input.setup, snapshot: snapshot,
                                  baselineAt: started, lastPoll: started, lastSuccess: started, nextPoll: time)
        record.connectionTimeZone = input.connectionTimeZone
        record.lastContact = time
        record.nextPoll = nextPoll(record, after: time)
        try persist(record)
        // A device that registers again (lost its secret) replaces its old entry: no double pushes.
        for old in records.values where old.id != id && old.deviceToken == input.deviceToken && old.bundleID == input.bundleID {
            try? remove(old.id)
        }
        Log.info("registriert \(Log.device(id)) (\(input.environment.rawValue)), \(records.count) Gerät(e)")
        return (id, secret, status(record))
    }

    public func update(id: String, _ input: UpdateInput) async throws -> DeviceStatus {
        guard let current = records[id] else { throw ServiceError.notFound }
        if let setup = input.setup, !config.allowsUntisServer(setup.server) { throw ServiceError.serverNotAllowed }
        let newConnection = input.connectionID ?? current.connectionID
        let newConnectionZone = input.connectionTimeZone ?? current.connectionTimeZoneIdentifier
        // The same Freigabe sent again after „Untis-Zugang prüfen“ (the app
        // reached WebUntis with it meanwhile) is a retry: new test fetch and
        // baseline as for a new one, otherwise the device stayed paused for good.
        // The device time zone only moves the schedule and the quiet hours:
        // no new baseline for it (lessons are read in the connection's zone).
        let needsBaseline = (input.setup.map { $0 != current.setup || current.state == .authFailed } ?? false)
            || newConnection != current.connectionID || newConnectionZone != current.connectionTimeZoneIdentifier
        var snapshot: CalendarSourceSnapshot?
        let started = now()
        if needsBaseline {
            snapshot = try await baseline(setup: input.setup ?? current.setup, connection: newConnection,
                                          connectionTimeZone: newConnectionZone, at: started)
        }
        guard var record = records[id] else { throw ServiceError.notFound }  // deleted meanwhile
        if let token = input.deviceToken { record.deviceToken = token }
        if let environment = input.environment { record.environment = environment }
        if let bundleID = input.bundleID { record.bundleID = bundleID }
        if let settings = input.settings { record.settings = settings }
        record.connectionID = newConnection
        if let zone = input.timeZone { record.timeZone = zone }
        if let zone = input.connectionTimeZone { record.connectionTimeZone = zone }
        if let setup = input.setup { record.setup = setup }
        if needsBaseline {
            record.snapshot = snapshot; record.baselineAt = started; record.lastSuccess = started; record.lastPoll = started
            record.failures = 0; record.authFailures = 0; record.lastError = nil; record.authNotice = .none
            if record.state == .authFailed { record.state = .active }
        }
        if input.deviceToken != nil || input.environment != nil, record.state == .tokenInvalid { record.state = .active }
        record.generation += 1
        record.updated = now()
        record.nextPoll = nextPoll(record, after: record.updated)
        try persist(record)
        Log.info("aktualisiert \(Log.device(id))\(needsBaseline ? " (neue Basis)" : "")")
        return status(record)
    }

    public func delete(id: String) throws {
        guard records[id] != nil else { throw ServiceError.notFound }
        try remove(id)
        Log.info("abgemeldet und gelöscht \(Log.device(id))")
    }

    public func changes(id: String, since: Date?) throws -> (changes: [ChangeEntry], status: DeviceStatus) {
        guard let record = records[id] else { throw ServiceError.notFound }
        let list = record.history.filter { since == nil || $0.detected > since! }
        return (list, status(record))
    }

    public func status(id: String) -> DeviceStatus? { records[id].map(status) }

    func status(_ record: DeviceRecord) -> DeviceStatus {
        DeviceStatus(deviceID: record.id, state: record.state, environment: record.environment, connectionID: record.connectionID,
                     lastPoll: record.lastPoll, lastSuccess: record.lastSuccess, nextPoll: record.nextPoll,
                     lastError: record.lastError, baselineAt: record.baselineAt)
    }

    /// Complete first fetch of the window: the comparison base (no notifications).
    private func baseline(setup: WebUntisSetup, connection: UUID, connectionTimeZone: String,
                          at time: Date) async throws -> CalendarSourceSnapshot {
        guard let zone = TimeZone(identifier: connectionTimeZone) else { throw ServiceError.storage("Zeitzone") }
        let calendar = DeviceRecord.calendar(connectionTimeZone)
        let window = PollSchedule.window(now: time, days: config.windowDays, calendar: calendar)
        do {
            let fetch = try await source.load(setup: setup, connection: connection, timeZone: zone, start: window.start,
                                              end: window.end, at: time)
            var snapshot = CalendarSourceSnapshot(connection: connection)
            try snapshot.merge(fetch)
            snapshot.homework = []
            return snapshot
        } catch let error as ServiceError {
            throw error
        } catch {
            throw ServiceError.untis(PollFailure.classify(error))
        }
    }

    // MARK: Loop

    /// One round: deliver what waited for the quiet end, poll due devices, clean up.
    public func tick() async {
        for id in records.keys.sorted() { await flushPending(id) }
        let time = now()
        for id in records.keys.sorted() {
            guard let record = records[id], record.state == .active, record.nextPoll <= time, !busy.contains(id) else { continue }
            if PollSchedule.isPollHour(time, config: config.schedule, calendar: record.calendar) {
                await poll(id)
            } else {
                var copy = record
                copy.nextPoll = nextPoll(copy, after: time)
                try? persist(copy)
            }
        }
        if lastMaintenance.map({ time.timeIntervalSince($0) >= 3600 }) ?? true {
            lastMaintenance = time
            maintenance(now: time)
        }
    }

    func nextPoll(_ record: DeviceRecord, after date: Date) -> Date {
        PollSchedule.nextAfterAttempt(now: date, failures: record.failures, minute: record.pollMinute(spread: config.schedule.spreadMinutes),
                                      config: config.schedule, calendar: record.calendar)
    }

    /// Fetches the window, compares with the stored snapshot and notifies.
    /// Lessons are read, days counted and texts written in the connection's
    /// time zone; quiet hours and the schedule follow the device's.
    public func poll(_ id: String) async {
        guard let start = records[id], start.state == .active, busy.insert(id).inserted else { return }
        defer { busy.remove(id) }
        let generation = start.generation
        let lessons = start.connectionCalendar
        let started = now()
        let window = PollSchedule.window(now: started, days: config.windowDays, calendar: lessons)
        let result: Result<CalendarTimetableFetch, Error>
        if !config.allowsUntisServer(start.setup.server) {
            result = .failure(UntisServerNotAllowed())
        } else {
            do {
                result = .success(try await source.load(setup: start.setup, connection: start.connectionID, timeZone: lessons.timeZone,
                                                        start: window.start, end: window.end, at: started))
            } catch { result = .failure(error) }
        }

        // The device was changed or deleted meanwhile: this result is stale.
        guard var record = records[id], record.generation == generation else { return }
        let time = now()
        record.lastPoll = started
        var fresh: [ChangeEntry] = []
        switch result {
        case .failure(let error):
            let failure = PollFailure.classify(error)
            record.failures += 1
            record.lastError = failure.message
            if failure == .authentication {
                record.authFailures += 1
                if record.authFailures >= 2 {
                    record.state = .authFailed
                    record.authNotice = .pending
                    record.updated = time
                }
            } else {
                // Only rejections in a row count („zweimal hintereinander“).
                record.authFailures = 0
            }
            Log.warn("Abruf fehlgeschlagen \(Log.device(id)): \(failure == .authentication ? "Anmeldung abgelehnt" : failure.message) (\(record.failures)×)")
        case .success(let fetch):
            let old = record.snapshot
            var new = old ?? CalendarSourceSnapshot(connection: record.connectionID)
            do {
                // A day that had lessons and comes back empty keeps its old
                // state: lessons that return are compared with it, never
                // reported as „zusätzlich“.
                try new.mergeKeepingEmptiedDays(fetch)
                new.homework = []
                let today = CivilDate(time, calendar: lessons)
                let detected = old == nil ? [] : detector.changes(old: old, new: new, now: time, calendar: lessons)
                // Deduplicated against the newest entry of the same lesson:
                // the same change again after another one is new (`~2`).
                var earlier = record.history.map(\.id)
                for change in detected where change.lesson.date < window.end && change.lesson.start > time {
                    let resolved = CalendarChangeRepeats.resolve(change.id, earlier: earlier)
                    guard resolved.isNew else { continue }
                    earlier.append(resolved.id)
                    fresh.append(ChangeEntry(id: resolved.id, kinds: change.kinds, title: CalendarLessonChange.notificationTitle,
                                             body: change.text, detected: time, day: change.lesson.date, entryID: change.lesson.id,
                                             periodID: change.lesson.key.sourceID, lessonStart: change.lesson.start,
                                             delivery: .pending))
                }
                Self.trim(&new, before: today.adding(days: -2))
                record.snapshot = new
                if old == nil { record.baselineAt = started }
                record.failures = 0; record.authFailures = 0; record.lastError = nil; record.lastSuccess = started
            } catch {
                record.failures += 1
                record.authFailures = 0
                record.lastError = PollFailure.classify(error).message
            }
        }
        let quiet = record.settings.isQuiet(time, calendar: record.calendar)
        for index in fresh.indices {
            fresh[index].delivery = !record.settings.changes ? .disabled : .pending
        }
        record.addHistory(fresh, now: time)
        record.nextPoll = nextPoll(record, after: time)
        do { try persist(record) } catch { Log.error("Speichern fehlgeschlagen \(Log.device(id)): \(error)"); return }
        if !fresh.isEmpty { Log.info("\(fresh.count) Änderung(en) erkannt \(Log.device(id))\(quiet ? " (Ruhezeit)" : "")") }
        // Immediate delivery outside the quiet hours (≤ 3 single pushes, else one summary).
        if !quiet { await flushPending(id, singleLimit: Self.maximumSinglePushes) }
    }

    /// Removes days before `day` from the comparison snapshot (bounded data).
    static func trim(_ snapshot: inout CalendarSourceSnapshot, before day: CivilDate) {
        for key in snapshot.days.keys { if let date = CivilDate(key), date < day { snapshot.days[key] = nil } }
        snapshot.lessons.removeAll { $0.date < day }
        snapshot.holidays = []
        snapshot.holidaysFetchedAt = nil
    }

    // MARK: Delivery

    /// Sends what is pending when the quiet hours are over: one push for one
    /// change, else one summary (`singleLimit` allows a few single pushes
    /// right after a poll). Lessons that have begun meanwhile expire.
    func flushPending(_ id: String, singleLimit: Int = 1) async {
        guard var record = records[id] else { return }
        let time = now()
        let calendar = record.calendar
        if record.settings.isQuiet(time, calendar: calendar) { return }
        if let wait = retryAfter[id], wait > time { return }
        if let wait = providerRetryAt, wait > time { return }
        var changed = false
        for index in record.history.indices where record.history[index].delivery == .pending {
            if !record.settings.changes { record.history[index].delivery = .disabled; changed = true }
            else if record.history[index].lessonStart <= time { record.history[index].delivery = .expired; changed = true }
        }
        // Nothing goes to a token APNs called invalid (waits for a new one).
        let authNotice = record.authNotice == .pending && record.state != .tokenInvalid
        let pending = record.state == .active ? record.history.filter { $0.delivery == .pending } : []
        if changed { try? persist(record) }
        guard !pending.isEmpty || authNotice else { return }
        let target = PushTarget(deviceToken: record.deviceToken, environment: record.environment, topic: record.bundleID)

        var outcomes: [(ids: [String], result: PushResult, summary: Bool)] = []
        if !pending.isEmpty {
            if pending.count <= singleLimit {
                for entry in pending {
                    outcomes.append(([entry.id], await sender.send(Self.message(entry, record: record), to: target), false))
                    if !Self.mayContinue(outcomes.last!.result) { break }
                }
            } else {
                outcomes.append((pending.map(\.id), await sender.send(Self.summaryMessage(pending, record: record, now: time), to: target), true))
            }
        }
        var authResult: PushResult?
        if authNotice, outcomes.allSatisfy({ Self.mayContinue($0.result) }) {
            authResult = await sender.send(Self.authMessage(record: record, now: time), to: target)
        }
        let results = outcomes.map(\.result) + (authResult.map { [$0] } ?? [])

        if results.contains(where: { if case .retryLater = $0 { return true }; return false }) {
            retryAfter[id] = time.addingTimeInterval(10 * 60)
        } else { retryAfter[id] = nil }
        if let reason = results.lazy.compactMap({ if case .providerError(let reason) = $0 { return reason }; return nil }).first {
            providerFailures += 1
            let pause = min(10 * 60 * pow(2, Double(min(providerFailures, 8) - 1)), 3 * 3600)
            providerRetryAt = time.addingTimeInterval(pause)
            Log.error("APNs lehnt den Dienst ab (\(reason)): apnsKeyID, teamID, apns.p8 und allowedBundleIDs prüfen. "
                      + "Nichts verworfen; nächster Versuch in \(Int(pause / 60)) min (\(providerFailures)×).")
        } else if results.contains(.delivered) {
            providerFailures = 0; providerRetryAt = nil
        }

        // The device may have changed meanwhile (PUT: new token, settings,
        // connection; generation bumped). The entries are updated by id as
        // long as they are still pending; what APNs said about the token
        // counts only for the token the push went to.
        guard var current = records[id] else { return }
        let sameTarget = PushTarget(deviceToken: current.deviceToken, environment: current.environment, topic: current.bundleID) == target
        for outcome in outcomes {
            for changeID in outcome.ids {
                guard let index = current.history.firstIndex(where: { $0.id == changeID && $0.delivery == .pending }) else { continue }
                switch outcome.result {
                case .delivered: current.history[index].delivery = outcome.summary ? .summarized : .sent
                case .retryLater: current.history[index].delivery = current.history[index].detected < time.addingTimeInterval(-3 * 3600) ? .failed : .pending
                case .providerError: break  // stays pending (expires when the lesson begins)
                case .invalidToken: if sameTarget { current.history[index].delivery = .failed }  // else: tried again with the new token
                case .rejected: current.history[index].delivery = .failed
                }
            }
            log(outcome.result, id: id, count: outcome.ids.count)
        }
        if let authResult {
            log(authResult, id: id, count: 1)
            if current.authNotice == .pending {
                switch authResult {
                case .delivered, .rejected: current.authNotice = .sent
                // Not shown: sent again after a new token, after the pause.
                case .invalidToken, .retryLater, .providerError: break
                }
            }
        }
        if sameTarget, results.contains(where: { if case .invalidToken = $0 { return true }; return false }) {
            current.state = .tokenInvalid
            current.updated = time
            Log.warn("Gerätetoken ungültig, Gerät pausiert \(Log.device(id))")
        }
        try? persist(current)
    }

    /// After this result further pushes to the same device are worthwhile now.
    static func mayContinue(_ result: PushResult) -> Bool {
        switch result {
        case .delivered, .rejected, .retryLater: true
        case .invalidToken, .providerError: false
        }
    }

    private func log(_ result: PushResult, id: String, count: Int) {
        switch result {
        case .delivered: Log.info("Push zugestellt an APNs \(Log.device(id)) (\(count) Änderung(en))")
        case .invalidToken(let reason): Log.warn("APNs: Token ungültig \(Log.device(id)): \(reason)")
        case .retryLater(let reason): Log.warn("APNs später erneut \(Log.device(id)): \(reason)")
        case .providerError(let reason): Log.error("APNs lehnt den Dienst ab \(Log.device(id)): \(reason)")
        case .rejected(let reason): Log.error("APNs abgelehnt \(Log.device(id)): \(reason)")
        }
    }

    static func threadID(_ record: DeviceRecord) -> String { "noty.calendar.changes." + record.connectionID.uuidString }

    static func message(_ entry: ChangeEntry, record: DeviceRecord) -> PushMessage {
        PushMessage(title: entry.title, body: entry.body, threadID: threadID(record), collapseID: entry.id, expiration: entry.lessonStart,
                    data: PushMessage.data(.change, [.connectionID: .string(record.connectionID.uuidString),
                                                     .changeID: .string(entry.id), .changeIDs: .strings([entry.id]),
                                                     .periodID: .string(entry.periodID), .day: .string(entry.day.description),
                                                     .entryID: .string(entry.entryID),
                                                     .lessonStart: .int(Int(entry.lessonStart.timeIntervalSince1970))]))
    }

    static func summaryMessage(_ entries: [ChangeEntry], record: DeviceRecord, now: Date) -> PushMessage {
        let ordered = entries.sorted { ($0.lessonStart, $0.id) < ($1.lessonStart, $1.id) }
        let text = CalendarLessonChange.summary(bodies: ordered.map(\.body))
        let first = ordered[0]
        return PushMessage(title: text.title, body: text.body, threadID: threadID(record),
                           collapseID: "summary." + APNs.collapseID(ordered.map(\.id).joined(separator: ",")),
                           expiration: ordered.map(\.lessonStart).max(),
                           data: PushMessage.data(.summary, [.connectionID: .string(record.connectionID.uuidString),
                                                             .changeIDs: .strings(Array(ordered.prefix(20).map(\.id))),
                                                             .day: .string(first.day.description), .entryID: .string(first.entryID),
                                                             .periodID: .string(first.periodID),
                                                             .lessonStart: .int(Int(first.lessonStart.timeIntervalSince1970))]))
    }

    static func authMessage(record: DeviceRecord, now: Date) -> PushMessage {
        PushMessage(title: authTitle, body: authBody,
                    threadID: threadID(record), collapseID: "auth." + record.connectionID.uuidString,
                    expiration: now.addingTimeInterval(3 * 86_400),
                    data: PushMessage.data(.auth, [.connectionID: .string(record.connectionID.uuidString)]))
    }

    /// Test push of the operator (`noty-push test-push`): proves topic,
    /// environment and key; tapping it opens nothing.
    public static func testMessage(now: Date) -> PushMessage {
        PushMessage(title: "noty calendar", body: "Testmitteilung des Mitteilungsdienstes.", threadID: "noty.calendar.test",
                    expiration: now.addingTimeInterval(3600), data: PushMessage.data(.test))
    }

    // MARK: Storage

    private func persist(_ record: DeviceRecord) throws {
        do { try store.save(record) } catch { throw ServiceError.storage("\(error)") }
        records[record.id] = record
    }

    private func remove(_ id: String) throws {
        do { try store.delete(id) } catch { throw ServiceError.storage("\(error)") }
        records[id] = nil
    }

    /// Deletes devices that stayed inactive (token invalid, Untis access
    /// rejected) for `inactiveRetentionDays`, and any device whose app did
    /// not contact the server for `noContactRetentionDays`: data minimization.
    func maintenance(now time: Date) {
        let limit = time.addingTimeInterval(-Double(config.inactiveRetentionDays) * 86_400)
        for record in records.values where record.state != .active && record.updated < limit && (record.lastSuccess ?? record.created) < limit {
            try? remove(record.id)
            Log.info("inaktives Gerät gelöscht \(Log.device(record.id))")
        }
        let contactLimit = time.addingTimeInterval(-Double(config.noContactRetentionDays) * 86_400)
        for record in records.values where record.contact < contactLimit {
            try? remove(record.id)
            Log.info("Gerät ohne Kontakt seit \(config.noContactRetentionDays) Tagen gelöscht \(Log.device(record.id))")
        }
        for id in records.keys.sorted() {
            guard var record = records[id] else { continue }
            let count = record.history.count
            record.addHistory([], now: time)
            if record.history.count != count { try? persist(record) }
        }
    }
}
