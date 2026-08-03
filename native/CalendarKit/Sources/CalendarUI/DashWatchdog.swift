// CC_DASH_DIAG watchdog: catches the main thread MID-BLOCK and prints its real stack.
// The suspect timers all came back clean while 150-1000ms frame gaps persisted, so the block
// lives outside our instrumented code — this samples it directly. A background thread polls
// the overlay's last-eval timestamp during the 2.5s post-press window; when the main thread
// goes stale >120ms it is briefly suspended, its frame-pointer chain walked (no allocation
// while suspended — the classic sampling-profiler deadlock hazard), resumed, and the captured
// addresses symbolicated with dladdr. Diagnostic-only; inert without CC_DASH_DIAG.

import Darwin
import Foundation

final class DashWatchdog: @unchecked Sendable {
    static let shared = DashWatchdog()

    private var mainThread: mach_port_t = 0
    private var started = false
    // Racy reads are fine: worst case a missed/spurious sample of a diagnostic.
    private var lastEval: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    private var windowUntil: CFAbsoluteTime = 0
    private var reported = false

    /// Main thread: the overlay's per-frame eval heartbeat.
    func noteEval() {
        lastEval = CFAbsoluteTimeGetCurrent()
    }

    /// Main thread: a hotkey press opens the observation window.
    func openWindow(seconds: Double) {
        if mainThread == 0 {
            mainThread = pthread_mach_thread_np(pthread_self())
        }
        lastEval = CFAbsoluteTimeGetCurrent()
        windowUntil = lastEval + seconds
        reported = false
        if !started {
            started = true
            let t = Thread { [weak self] in self?.loop() }
            t.name = "dash-diag-watchdog"
            t.qualityOfService = .userInitiated
            t.start()
        }
    }

    private func loop() {
        while true {
            usleep(25000)
            let now = CFAbsoluteTimeGetCurrent()
            guard now < windowUntil else { continue }
            let stale = now - lastEval
            if stale < 0.05 {
                reported = false
            } else if stale > 0.12, !reported {
                reported = true // one stack per gap — the FIRST catch shows the culprit
                dumpMainStack(staleMs: Int(stale * 1000))
            }
        }
    }

    /// mach/arm/thread_status.h's __darwin_arm_thread_state64, declared locally: the Mach ARM
    /// types aren't exposed to Swift in every build context (the Xcode app target failed to
    /// find them while the SPM CLI build resolved them), so we carry the ABI layout ourselves.
    private struct ARMThreadState64 {
        var x: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                UInt64, UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                                           0, 0, 0, 0, 0, 0, 0, 0, 0)
        var fp: UInt64 = 0
        var lr: UInt64 = 0
        var sp: UInt64 = 0
        var pc: UInt64 = 0
        var cpsr: UInt32 = 0
        var flags: UInt32 = 0
    }

    private static let armThreadState64Flavor: thread_state_flavor_t = 6 // ARM_THREAD_STATE64

    private func dumpMainStack(staleMs: Int) {
        #if arch(arm64)
            var addrs = [UInt64](repeating: 0, count: 64)
            var n = 0
            guard thread_suspend(mainThread) == KERN_SUCCESS else {
                print("[dash-diag] WATCHDOG: suspend failed")
                return
            }
            var state = ARMThreadState64()
            var count = mach_msg_type_number_t(
                MemoryLayout<ARMThreadState64>.size / MemoryLayout<natural_t>.size
            )
            let kr = withUnsafeMutablePointer(to: &state) {
                $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                    thread_get_state(mainThread, Self.armThreadState64Flavor, $0, &count)
                }
            }
            if kr == KERN_SUCCESS {
                let mask: UInt64 = 0x0000_7FFF_FFFF_FFFF // strip ptrauth bits
                addrs[n] = state.pc & mask
                n += 1
                var fp = state.fp & mask
                // Walk the frame-pointer chain: [fp] = caller fp, [fp+8] = return address.
                while n < 62, fp > 0x1000, fp % 8 == 0 {
                    guard let p = UnsafeRawPointer(bitPattern: UInt(fp)) else { break }
                    let nextFP = p.load(as: UInt64.self) & mask
                    let lr = p.load(fromByteOffset: 8, as: UInt64.self) & mask
                    if lr <= 0x1000 {
                        break
                    }
                    addrs[n] = lr
                    n += 1
                    if nextFP <= fp {
                        break
                    }
                    fp = nextFP
                }
            }
            thread_resume(mainThread) // resume BEFORE symbolication (dladdr may allocate)
            guard n > 0 else {
                print("[dash-diag] WATCHDOG: main blocked \(staleMs)ms — state capture failed")
                return
            }
            var out = "[dash-diag] WATCHDOG: main blocked ≥\(staleMs)ms — stack:\n"
            for i in 0 ..< n {
                var info = Dl_info()
                if let a = UnsafeRawPointer(bitPattern: UInt(addrs[i])), dladdr(a, &info) != 0,
                   let sym = info.dli_sname {
                    out += "    \(String(cString: sym))\n"
                } else {
                    out += String(format: "    0x%llx\n", addrs[i])
                }
            }
            print(out, terminator: "")
        #else
            print("[dash-diag] WATCHDOG: main blocked ≥\(staleMs)ms (stack capture is arm64-only)")
        #endif
    }
}
