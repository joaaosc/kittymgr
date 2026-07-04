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

    /// Exit status peeked from a dead child corelibs has not reaped yet, or
    /// nil if it is still running or was killed by a signal.
    static func peekedCleanExitStatus(pid: pid_t) -> Int32? {
        var info = siginfo_t()
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0,
              info._sifields._sigchld.si_pid == pid,
              info.si_code == Int32(CLD_EXITED) else { return nil }
        return info._sifields._sigchld.si_status
    }
    #endif
}
