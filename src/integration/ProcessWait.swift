import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Portable, deadline-bounded replacement for `Process.waitUntilExit()`.
///
/// On Linux, swift-corelibs-foundation's `waitUntilExit()` can block forever
/// when the child exits before the wait is entered, and `isRunning` has a
/// second failure mode: corelibs notices the exit through an internal
/// notification descriptor that descendants inherit, so a live grandchild
/// keeps `isRunning` true long after the child died. The Linux path therefore
/// confirms the real state with `waitid(..., WNOWAIT)` — a peek that leaves
/// the zombie for corelibs' own reaper. On Darwin `isRunning` is exit-event
/// driven and descendant-immune, but the native wait has no deadline and
/// `ProcessRunner` races the child's exit against a real timeout — so both
/// platforms poll.
enum ProcessWait {
    /// Waits for `process` to exit. Returns `false` if it is still running
    /// after `timeout` seconds (the process is left running; the caller
    /// decides whether to escalate to SIGTERM/SIGKILL or degrade).
    @discardableResult
    static func waitForExit(_ process: Process, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while process.isRunning {
            #if os(Linux)
            if hasExited(pid: process.processIdentifier) { return true }
            #endif
            if Date() > deadline { return false }
            usleep(10_000)
        }
        return true
    }

    #if os(Linux)
    /// Whether the child is dead (possibly a zombie corelibs has not observed
    /// yet). `WNOWAIT` peeks without reaping, so corelibs' bookkeeping still
    /// collects the exit itself.
    static func hasExited(pid: pid_t) -> Bool {
        var info = siginfo_t()
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else {
            // ECHILD: corelibs already reaped it — certainly exited.
            return errno == ECHILD
        }
        // With WNOHANG, si_pid stays 0 while the child is still running.
        return info._sifields._sigchld.si_pid == pid
    }

    /// Child state peeked without reaping. The four cases are distinct on
    /// purpose: only `.reaped` means the exit status is unrecoverable *here*
    /// but about to surface through corelibs' own bookkeeping.
    enum PeekedExit {
        /// No zombie yet — the child is still running.
        case running
        /// Exited cleanly with this status; the zombie is left for corelibs.
        case exited(Int32)
        /// Dead, but killed by a signal — there is no clean exit status.
        case signaled
        /// ECHILD: corelibs' reaper already collected the child, so its exit
        /// state now lives only in `terminationStatus`, which becomes safe to
        /// read the moment corelibs flips `isRunning`.
        case reaped
    }

    /// Peeks the child's exit state with `WNOWAIT`, so corelibs' bookkeeping
    /// still collects the zombie itself.
    static func peekExit(pid: pid_t) -> PeekedExit {
        var info = siginfo_t()
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else {
            return errno == ECHILD ? .reaped : .signaled
        }
        if info._sifields._sigchld.si_pid != pid { return .running }
        if info.si_code == Int32(CLD_EXITED) {
            return .exited(info._sifields._sigchld.si_status)
        }
        return .signaled
    }
    #endif
}
