import Foundation
import Darwin
import OSLog
import os
import QuartzCore
import MachO
import NotebookCore

/// Diagnostics for main-thread stalls (Feedback 33: multi-second hangs at high
/// zoom). Two modes:
/// - Always on (`installWatchdog`, from `Diagnostics.start`): a run-loop
///   observer notes every main iteration of 250 ms or more as a `hang`
///   breadcrumb; a background watchdog samples the main thread's frame-pointer
///   chain once an iteration reaches 2 s and stores an `appHang` report with
///   that stack (rewritten with the final duration when main recovers).
///   Costs one lock per run-loop wake-up and a thread that wakes every 100 ms.
/// - Verbose (Einstellungen › Diagnose › Hänger-Diagnose, `install`): in
///   addition `hit` counts named code paths per iteration, and stalls are
///   sampled at 0.7, 1.5, 3 and 10 s into the system log and
///   Documents/Diagnose/haenger.txt.
/// Records only addresses (image + offset) and counters, never document content.
enum HangProbe {
    private static let log = Logger(subsystem: "de.la.noty", category: "hang-probe")
    private struct PendingHang: Sendable {
        var iteration: UInt64
        var id: String
        var createdAt: Int64
        var stack: [DiagnosticFrame]
        var test: Bool
    }
    private struct State: Sendable {
        var counts: [String: Int] = [:]
        var iteration: UInt64 = 0
        var iterationStart = CACurrentMediaTime()
        /// Main sleeps in its run loop: that is no stall.
        var idle = false
        /// The 2 s report of the current iteration, finished when it ends.
        var pending: PendingHang?
        /// The hidden test menu's hang is running.
        var testing = false
    }
    /// A heap-allocated lock: `&` on a Swift `static var` gives no stable address.
    private static let state = OSAllocatedUnfairLock(initialState: State())
    nonisolated(unsafe) private static var mainThread: thread_act_t = 0
    private static let maxFrames = 96
    nonisolated(unsafe) private static let frames = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
    nonisolated(unsafe) private static var watching = false
    nonisolated(unsafe) private static var installed = false
    /// The verbose mode (Settings › Diagnose, read at launch). Also gates the
    /// editor's timing and input traces, so normal use logs nothing per touch.
    static var isInstalled: Bool { installed }

    /// Verbose mode on top of the watchdog.
    @MainActor static func install() {
        guard !installed else { return }
        installed = true
        installWatchdog()
        write("=== Start \(Date().formatted(.iso8601)), Build \(Diagnostics.build)")
    }

    /// The always-on watchdog (`Diagnostics.start`).
    @MainActor static func installWatchdog() {
        guard !watching else { return }
        watching = true
        mainThread = mach_thread_self()
        // Allocates: must not happen on first use, while main is suspended.
        _ = frames
        let observer = CFRunLoopObserverCreateWithHandler(nil,
            CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
            let sleeping = activity == .beforeWaiting
            let verbose = installed
            let (elapsed, snapshot, finished) = state.withLock { state -> (Double, [String: Int], PendingHang?) in
                let elapsed = CACurrentMediaTime() - state.iterationStart
                let stalled = elapsed > 0.25 && !state.idle
                let snapshot = stalled && verbose ? state.counts : [:]
                let finished = state.pending?.iteration == state.iteration ? state.pending : nil
                if finished != nil { state.pending = nil }
                state.idle = sleeping
                if verbose { state.counts.removeAll(keepingCapacity: true) }
                state.iteration &+= 1; state.iterationStart = CACurrentMediaTime()
                return (stalled ? elapsed : 0, snapshot, finished)
            }
            guard elapsed > 0 else { return }
            let ms = Int(elapsed * 1000)
            Diagnostics.noteHang(milliseconds: ms)
            if let finished {
                Diagnostics.queue.async {
                    Diagnostics.hangReport(milliseconds: ms, stack: finished.stack, id: finished.id,
                                           createdAt: finished.createdAt, test: finished.test)
                    Uploader.shared.schedule(after: 5)
                }
            }
            if !snapshot.isEmpty { report(elapsed: elapsed, counts: snapshot) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let thread = Thread { watchdog() }
        thread.name = "noty.hang-probe"; thread.qualityOfService = .utility
        thread.start()
    }

    /// Main thread only. Not verbose: a single branch; else one lock and a dictionary increment.
    static func hit(_ tag: StaticString) {
        guard installed else { return }
        let key = "\(tag)"
        state.withLock { $0.counts[key, default: 0] += 1 }
    }

    /// The hidden test menu: blocks main for `seconds`, marked as a test.
    @MainActor static func testHang(seconds: Double) {
        Diagnostics.note("test.hang", ["ms": Int(seconds * 1000)])
        state.withLock { $0.testing = true }
        Thread.sleep(forTimeInterval: seconds)
        state.withLock { $0.testing = false }
    }

    private static func report(elapsed: Double, counts: [String: Int]) {
        let text = counts.sorted { $0.value > $1.value }.prefix(24).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        log.error("Slow main iteration \(Int(elapsed * 1000), privacy: .public) ms: \(text, privacy: .public)")
        if elapsed >= 0.7 { write("Langsam \(Int(elapsed * 1000)) ms: \(text)") }
    }

    /// Without USB the system log cannot be read: the same addresses and
    /// counters also go to Documents/Diagnose (Dateien › Auf meinem iPad › noty).
    private static let fileQueue = DispatchQueue(label: "noty.hang-probe.file", qos: .utility)
    private static func write(_ text: String) {
        fileQueue.async {
            guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Diagnose", isDirectory: true) else { return }
            let url = folder.appendingPathComponent("haenger.txt")
            let data = Data((text + "\n").utf8)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if size >= 2_000_000 {
                // Rotated like the input probe: the previous history stays as .1.
                let old = folder.appendingPathComponent("haenger.1.txt")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: url, to: old)
            }
            guard size > 0, size < 2_000_000, let handle = try? FileHandle(forWritingTo: url) else {
                try? data.write(to: url, options: .atomic); return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    private static func watchdog() {
        var watchedIteration: UInt64 = .max
        var samples = 0
        var reported = false
        let reportAfter = Double(DiagnosticThresholds.hangReportMilliseconds) / 1000
        while true {
            usleep(100_000)
            let (current, elapsed, live, sleeping, testing) = state.withLock { state in
                (state.iteration, CACurrentMediaTime() - state.iterationStart, state.counts, state.idle, state.testing)
            }
            if current != watchedIteration { watchedIteration = current; samples = 0; reported = false }
            guard !sleeping else { continue }
            if installed {
                // Sample at ~0.7 s, ~1.5 s, ~3 s and ~10 s of one stalled iteration.
                let due = samples == 0 ? 0.7 : samples == 1 ? 1.5 : samples == 2 ? 3.0 : samples == 3 ? 10.0 : .infinity
                if elapsed >= due {
                    samples += 1
                    let count = sampleMainThread()
                    symbolizeAndLog(count: count, elapsed: elapsed, sample: samples, counts: live)
                }
            }
            if !reported, elapsed >= reportAfter {
                reported = true
                let stack = diagnosticFrames(count: sampleMainThread())
                let pending = PendingHang(iteration: current, id: UUID().uuidString,
                                          createdAt: DiagnosticReport.milliseconds(Date()), stack: stack, test: testing)
                let stillStalled = state.withLock { state -> Bool in
                    guard state.iteration == current else { return false }
                    state.pending = pending; return true
                }
                // Written now: if the system ends the app during the stall, the report survives.
                if stillStalled {
                    Diagnostics.hangReport(milliseconds: Int(elapsed * 1000), stack: stack, id: pending.id,
                                           createdAt: pending.createdAt, test: testing)
                }
            }
        }
    }

    /// Image name, offset into the image and its Mach-O UUID per address.
    private static func diagnosticFrames(count: Int) -> [DiagnosticFrame] {
        (0..<count).map { index in
            let address = frames[index]
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let base = info.dli_fbase else {
                return DiagnosticFrame(image: "?", offset: UInt64(address))
            }
            let image = info.dli_fname.map { String(cString: $0) }.map { ($0 as NSString).lastPathComponent } ?? "?"
            return DiagnosticFrame(image: image, offset: UInt64(address - UInt(bitPattern: base)), uuid: imageUUID(base))
        }
    }

    nonisolated(unsafe) private static var uuids: [UInt: String] = [:]
    /// LC_UUID of a loaded image; watchdog thread only.
    private static func imageUUID(_ base: UnsafeMutableRawPointer) -> String? {
        let key = UInt(bitPattern: base)
        if let known = uuids[key] { return known }
        let header = base.assumingMemoryBound(to: mach_header_64.self).pointee
        guard header.magic == MH_MAGIC_64 else { return nil }
        var command = base.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self).pointee
            if load.cmd == UInt32(LC_UUID) {
                let uuid = command.assumingMemoryBound(to: uuid_command.self).pointee.uuid
                let text = UUID(uuid: uuid).uuidString
                uuids[key] = text
                return text
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }

    /// Suspends main only while copying raw return addresses into a
    /// preallocated buffer: no allocation or locks while it is stopped.
    private static func sampleMainThread() -> Int {
        guard mainThread != 0, thread_suspend(mainThread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(mainThread) }
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(mainThread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &stateCount)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let mask: UInt = 0x0000_000F_FFFF_FFFF // strip pointer-authentication bits
        var n = 0
        frames[n] = UInt(state.__pc) & mask; n += 1
        frames[n] = UInt(state.__lr) & mask; n += 1
        var fp = UInt(state.__fp)
        var pair: (UInt, UInt) = (0, 0)
        while n < maxFrames, fp != 0, fp & 7 == 0 {
            var size: vm_size_t = 0
            let ok = withUnsafeMutablePointer(to: &pair) {
                vm_read_overwrite(mach_task_self_, vm_address_t(fp), vm_size_t(MemoryLayout<(UInt, UInt)>.size),
                                  vm_address_t(UInt(bitPattern: $0)), &size) == KERN_SUCCESS
            }
            guard ok, pair.1 != 0, pair.0 > fp else { break }
            frames[n] = pair.1 & mask; n += 1
            fp = pair.0
        }
        return n
    }

    private static func symbolizeAndLog(count: Int, elapsed: Double, sample: Int, counts: [String: Int]) {
        var lines: [String] = []
        for index in 0..<count {
            let address = frames[index]
            var info = Dl_info()
            if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let base = info.dli_fbase {
                let image = info.dli_fname.map { String(cString: $0) }.map { ($0 as NSString).lastPathComponent } ?? "?"
                let offset = address - UInt(bitPattern: base)
                let symbol = info.dli_sname.map { String(cString: $0) } ?? ""
                lines.append("\(index) \(image)+0x\(String(offset, radix: 16)) \(symbol)")
            } else {
                lines.append("\(index) 0x\(String(address, radix: 16))")
            }
        }
        let tags = counts.sorted { $0.value > $1.value }.prefix(24).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        log.error("Main thread stalled \(Int(elapsed * 1000), privacy: .public) ms (sample \(sample, privacy: .public)); paths: \(tags, privacy: .public)")
        write("Haenger \(Int(elapsed * 1000)) ms, Probe \(sample), Pfade: \(tags)\n" + lines.joined(separator: "\n"))
        // Several short records survive syslog line limits better than one long one.
        stride(from: 0, to: lines.count, by: 12).forEach { start in
            let chunk = lines[start..<min(lines.count, start + 12)].joined(separator: " | ")
            log.error("Stack \(sample, privacy: .public): \(chunk, privacy: .public)")
        }
    }
}
