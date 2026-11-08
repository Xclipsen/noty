import Foundation
import NotebookCore

public struct RegistrationInput: Sendable {
    public var deviceToken: String
    public var environment: APNsEnvironment
    public var bundleID: String
    public var connectionID: UUID
    public var timeZone: String
    public var settings: DeviceSettings
    public var setup: WebUntisSetup
    public init(deviceToken: String, environment: APNsEnvironment, bundleID: String, connectionID: UUID, timeZone: String,
                settings: DeviceSettings, setup: WebUntisSetup) {
        self.deviceToken = deviceToken; self.environment = environment; self.bundleID = bundleID; self.connectionID = connectionID
        self.timeZone = timeZone; self.settings = settings; self.setup = setup
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
    public init(deviceToken: String? = nil, environment: APNsEnvironment? = nil, bundleID: String? = nil, connectionID: UUID? = nil,
                timeZone: String? = nil, settings: DeviceSettings? = nil, setup: WebUntisSetup? = nil) {
        self.deviceToken = deviceToken; self.environment = environment; self.bundleID = bundleID; self.connectionID = connectionID
        self.timeZone = timeZone; self.settings = settings; self.setup = setup
    }
}

public enum ServiceError: Error, Equatable {
    case limitReached
    case notFound
    /// The test request with the (new) Freigabe failed.
    case untis(PollFailure)
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

    public func register(_ input: RegistrationInput) async throws -> (deviceID: String, secret: String, status: DeviceStatus) {
        func others() -> Int { records.values.filter { !($0.deviceToken == input.deviceToken && $0.bundleID == input.bundleID) }.count }
        guard others() < config.maxDevices else { throw ServiceError.limitReached }
        let started = now()
        let snapshot = try await baseline(setup: input.setup, connection: input.connectionID, timeZone: input.timeZone, at: started)
        guard others() < config.maxDevices else { throw ServiceError.limitReached }  // re-check after the await
        let id = UUID().uuidString.lowercased()
        let secret = Secrets.deviceSecret()
        let time = now()
        var record = DeviceRecord(id: id, secretHash: Secrets.hash(secret), created: time, updated: time, deviceToken: input.deviceToken,
                                  environment: input.environment, bundleID: input.bundleID, connectionID: input.connectionID,
                                  timeZone: input.timeZone, settings: input.settings, setup: input.setup, snapshot: snapshot,
                                  baselineAt: started, lastPoll: started, lastSuccess: started, nextPoll: time)
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
        let newConnection = input.connectionID ?? current.connectionID
        let newZone = input.timeZone ?? current.timeZone
        // The same Freigabe sent again after „Untis-Zugang prüfen“ (the app
        // reached WebUntis with it meanwhile) is a retry: new test fetch and
        // baseline as for a new one, otherwise the device stayed paused for good.
        let needsBaseline = (input.setup.map { $0 != current.setup || current.state == .authFailed } ?? false)
            || newConnection != current.connectionID || newZone != current.timeZone
        var snapshot: CalendarSourceSnapshot?
        let started = now()
        if needsBaseline {
            snapshot = try await baseline(setup: input.setup ?? current.setup, connection: newConnection, timeZone: newZone, at: started)
        }
        guard var record = records[id] else { throw ServiceError.notFound }  // deleted meanwhile
        if let token = input.deviceToken { record.deviceToken = token }
        if let environment = input.environment { record.environment = environment }
        if let bundleID = input.bundleID { record.bundleID = bundleID }
        if let settings = input.settings { record.settings = settings }
        record.connectionID = newConnection
        record.timeZone = newZone
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
    private func baseline(setup: WebUntisSetup, connection: UUID, timeZone: String, at time: Date) async throws -> CalendarSourceSnapshot {
        guard let zone = TimeZone(identifier: timeZone) else { throw ServiceError.storage("Zeitzone") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
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
    public func poll(_ id: String) async {
        guard let start = records[id], start.state == .active, busy.insert(id).inserted else { return }
        defer { busy.remove(id) }
        let generation = start.generation
        let calendar = start.calendar
        let started = now()
        let window = PollSchedule.window(now: started, days: config.windowDays, calendar: calendar)
        let result: Result<CalendarTimetableFetch, Error>
        do {
            result = .success(try await source.load(setup: start.setup, connection: start.connectionID, timeZone: calendar.timeZone,
                                                    start: window.start, end: window.end, at: started))
        } catch { result = .failure(error) }

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
            }
            Log.warn("Abruf fehlgeschlagen \(Log.device(id)): \(failure == .authentication ? "Anmeldung abgelehnt" : failure.message) (\(record.failures)×)")
        case .success(let fetch):
            let old = record.snapshot
            var new = old ?? CalendarSourceSnapshot(connection: record.connectionID)
            do {
                try new.merge(fetch)
                new.homework = []
                let known = Set(record.history.map(\.id))
                let today = CivilDate(time, calendar: calendar)
                let detected = old == nil ? [] : detector.changes(old: old, new: new, now: time, calendar: calendar)
                for change in detected where !known.contains(change.id) && change.lesson.date < window.end
                    && change.lesson.start > time && fresh.allSatisfy({ $0.id != change.id }) {
                    fresh.append(ChangeEntry(id: change.id, kinds: change.kinds, title: ChangeText.title, body: change.text,
                                             detected: time, day: change.lesson.date, entryID: change.lesson.id,
                                             periodID: change.lesson.key.sourceID, lessonStart: change.lesson.start,
                                             delivery: .pending))
                }
                Self.trim(&new, before: today.adding(days: -2))
                record.snapshot = new
                if old == nil { record.baselineAt = started }
                record.failures = 0; record.authFailures = 0; record.lastError = nil; record.lastSuccess = started
            } catch {
                record.failures += 1
                record.lastError = PollFailure.classify(error).message
            }
        }
        let quiet = record.settings.isQuiet(time, calendar: calendar)
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
        var changed = false
        for index in record.history.indices where record.history[index].delivery == .pending {
            if !record.settings.changes { record.history[index].delivery = .disabled; changed = true }
            else if record.history[index].lessonStart <= time { record.history[index].delivery = .expired; changed = true }
        }
        let authNotice = record.authNotice == .pending
        let pending = record.state == .active ? record.history.filter { $0.delivery == .pending } : []
        if changed { try? persist(record) }
        guard !pending.isEmpty || authNotice else { return }
        let target = PushTarget(deviceToken: record.deviceToken, environment: record.environment, topic: record.bundleID)
        let generation = record.generation

        var outcomes: [(ids: [String], result: PushResult, summary: Bool)] = []
        if !pending.isEmpty {
            if pending.count <= singleLimit {
                for entry in pending {
                    outcomes.append(([entry.id], await sender.send(Self.message(entry, record: record), to: target), false))
                    if case .invalidToken = outcomes.last!.result { break }
                }
            } else {
                outcomes.append((pending.map(\.id), await sender.send(Self.summaryMessage(pending, record: record, now: time), to: target), true))
            }
        }
        var authResult: PushResult?
        if authNotice, !outcomes.contains(where: { if case .invalidToken = $0.result { return true }; return false }) {
            authResult = await sender.send(Self.authMessage(record: record, now: time), to: target)
        }

        if outcomes.contains(where: { if case .retryLater = $0.result { return true }; return false })
            || { if case .retryLater = authResult { return true }; return false }() {
            retryAfter[id] = time.addingTimeInterval(10 * 60)
        } else { retryAfter[id] = nil }
        guard var current = records[id], current.generation == generation else { return }
        for outcome in outcomes {
            for changeID in outcome.ids {
                guard let index = current.history.firstIndex(where: { $0.id == changeID && $0.delivery == .pending }) else { continue }
                switch outcome.result {
                case .delivered: current.history[index].delivery = outcome.summary ? .summarized : .sent
                case .retryLater: current.history[index].delivery = current.history[index].detected < time.addingTimeInterval(-3 * 3600) ? .failed : .pending
                case .invalidToken, .rejected: current.history[index].delivery = .failed
                }
            }
            log(outcome.result, id: id, count: outcome.ids.count)
        }
        if let authResult {
            log(authResult, id: id, count: 1)
            switch authResult {
            case .delivered, .rejected, .invalidToken: current.authNotice = .sent
            case .retryLater: break
            }
        }
        if outcomes.contains(where: { if case .invalidToken = $0.result { return true }; return false })
            || { if case .invalidToken = authResult { return true }; return false }() {
            current.state = .tokenInvalid
            current.updated = time
            Log.warn("Gerätetoken ungültig, Gerät pausiert \(Log.device(id))")
        }
        try? persist(current)
    }

    private func log(_ result: PushResult, id: String, count: Int) {
        switch result {
        case .delivered: Log.info("Push zugestellt an APNs \(Log.device(id)) (\(count) Änderung(en))")
        case .invalidToken(let reason): Log.warn("APNs: Token ungültig \(Log.device(id)): \(reason)")
        case .retryLater(let reason): Log.warn("APNs später erneut \(Log.device(id)): \(reason)")
        case .rejected(let reason): Log.error("APNs abgelehnt \(Log.device(id)): \(reason)")
        }
    }

    static func threadID(_ record: DeviceRecord) -> String { "noty.calendar.changes." + record.connectionID.uuidString }

    static func message(_ entry: ChangeEntry, record: DeviceRecord) -> PushMessage {
        PushMessage(title: entry.title, body: entry.body, threadID: threadID(record), collapseID: entry.id, expiration: entry.lessonStart,
                    data: ["kind": .string("change"), "connectionID": .string(record.connectionID.uuidString),
                           "changeID": .string(entry.id), "changeIDs": .strings([entry.id]), "periodID": .string(entry.periodID),
                           "day": .string(entry.day.description), "entryID": .string(entry.entryID),
                           "lessonStart": .int(Int(entry.lessonStart.timeIntervalSince1970))])
    }

    static func summaryMessage(_ entries: [ChangeEntry], record: DeviceRecord, now: Date) -> PushMessage {
        let ordered = entries.sorted { ($0.lessonStart, $0.id) < ($1.lessonStart, $1.id) }
        let text = ChangeText.summary(ordered.map(\.body))
        let first = ordered[0]
        return PushMessage(title: text.title, body: text.body, threadID: threadID(record),
                           collapseID: "summary." + APNs.collapseID(ordered.map(\.id).joined(separator: ",")),
                           expiration: ordered.map(\.lessonStart).max(),
                           data: ["kind": .string("summary"), "connectionID": .string(record.connectionID.uuidString),
                                  "changeIDs": .strings(Array(ordered.prefix(20).map(\.id))), "day": .string(first.day.description),
                                  "entryID": .string(first.entryID), "periodID": .string(first.periodID),
                                  "lessonStart": .int(Int(first.lessonStart.timeIntervalSince1970))])
    }

    static func authMessage(record: DeviceRecord, now: Date) -> PushMessage {
        PushMessage(title: "Untis-Zugang prüfen",
                    body: "Der Stundenplan kann nicht mehr abgerufen werden. Bitte in noty calendar die WebUntis-Freigabe neu verbinden.",
                    threadID: threadID(record), collapseID: "auth." + record.connectionID.uuidString,
                    expiration: now.addingTimeInterval(3 * 86_400),
                    data: ["kind": .string("auth"), "connectionID": .string(record.connectionID.uuidString)])
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
    /// rejected) for `inactiveRetentionDays`: data minimization.
    func maintenance(now time: Date) {
        let limit = time.addingTimeInterval(-Double(config.inactiveRetentionDays) * 86_400)
        for record in records.values where record.state != .active && record.updated < limit && (record.lastSuccess ?? record.created) < limit {
            try? remove(record.id)
            Log.info("inaktives Gerät gelöscht \(Log.device(record.id))")
        }
        for id in records.keys.sorted() {
            guard var record = records[id] else { continue }
            let count = record.history.count
            record.addHistory([], now: time)
            if record.history.count != count { try? persist(record) }
        }
    }
}
