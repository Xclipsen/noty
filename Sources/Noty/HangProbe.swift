import Foundation
import Darwin
import OSLog
import QuartzCore

/// Diagnostics for main-thread stalls (Feedback 33: multi-second hangs at high
/// zoom). A background watchdog samples the main thread's frame-pointer chain
/// when one run-loop iteration exceeds 0.7 s; `hit` counts named code paths per
/// iteration so a feedback loop shows up as an outlier. Logs only addresses
/// (image + offset) and counters, never document content.
enum HangProbe {
    private static let log = Logger(subsystem: "de.la.noty", category: "hang-probe")
    nonisolated(unsafe) private static var lock = os_unfair_lock()
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    nonisolated(unsafe) private static var iteration: UInt64 = 0
    nonisolated(unsafe) private static var iterationStart = CACurrentMediaTime()
    nonisolated(unsafe) private static var mainThread: thread_act_t = 0
    private static let maxFrames = 96
    nonisolated(unsafe) private static let frames = UnsafeMutablePointer<UInt>.allocate(capacity: maxFrames)
    nonisolated(unsafe) private static var installed = false

    @MainActor static func install() {
        guard !installed else { return }
        installed = true
        mainThread = mach_thread_self()
        let observer = CFRunLoopObserverCreateWithHandler(nil,
            CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, activity in
            os_unfair_lock_lock(&lock)
            let elapsed = CACurrentMediaTime() - iterationStart
            let snapshot = elapsed > 0.25 ? counts : [:]
            counts.removeAll(keepingCapacity: true)
            iteration &+= 1; iterationStart = CACurrentMediaTime()
            os_unfair_lock_unlock(&lock)
            if !snapshot.isEmpty { report(elapsed: elapsed, counts: snapshot) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        let thread = Thread { watchdog() }
        thread.name = "noty.hang-probe"; thread.qualityOfService = .utility
        thread.start()
    }

    /// Main thread only. Cheap: one lock and a dictionary increment.
    static func hit(_ tag: StaticString) {
        os_unfair_lock_lock(&lock)
        counts["\(tag)", default: 0] += 1
        os_unfair_lock_unlock(&lock)
    }

    private static func report(elapsed: Double, counts: [String: Int]) {
        let text = counts.sorted { $0.value > $1.value }.prefix(24).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        log.error("Slow main iteration \(Int(elapsed * 1000), privacy: .public) ms: \(text, privacy: .public)")
    }

    private static func watchdog() {
        var sampledIteration: UInt64 = .max
        var samples = 0
        while true {
            usleep(100_000)
            os_unfair_lock_lock(&lock)
            let current = iteration, elapsed = CACurrentMediaTime() - iterationStart
            let live = counts
            os_unfair_lock_unlock(&lock)
            if current != sampledIteration { samples = 0 }
            // Sample at ~0.7 s, ~1.5 s and ~3 s of one stalled iteration.
            let due = samples == 0 ? 0.7 : samples == 1 ? 1.5 : samples == 2 ? 3.0 : .infinity
            guard elapsed >= due else { continue }
            sampledIteration = current; samples += 1
            let count = sampleMainThread()
            symbolizeAndLog(count: count, elapsed: elapsed, sample: samples, counts: live)
        }
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
        // Several short records survive syslog line limits better than one long one.
        stride(from: 0, to: lines.count, by: 12).forEach { start in
            let chunk = lines[start..<min(lines.count, start + 12)].joined(separator: " | ")
            log.error("Stack \(sample, privacy: .public): \(chunk, privacy: .public)")
        }
    }
}
