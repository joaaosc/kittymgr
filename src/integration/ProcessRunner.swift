import Foundation
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// Full output of a completed (or force-terminated) subprocess run.
struct ProcessOutput {
    let status: Int32
    let stdout: Data
    let stderr: Data
    /// The child hit the wall-clock timeout and was terminated. `status` is
    /// meaningless in that case; `stdout`/`stderr` hold whatever had been
    /// drained up to the kill.
    let timedOut: Bool
}

/// Runs a subprocess draining stdout and stderr concurrently while it
/// executes, so a child that fills either pipe buffer can never deadlock the
/// parent, and enforces a hard wall-clock timeout.
///
/// The wait races the child's *exit* against the deadline — never the pipes'
/// EOF. On timeout the child is sent SIGTERM, then SIGKILL if needed, reaped,
/// and the call returns immediately with the output captured so far. On a
/// normal exit the drains are awaited within the remaining budget, so output
/// is complete; EOF that never arrives (a descendant inherited a write end)
/// is reported as a timeout rather than returned as truncated success. No
/// wait in here is unbounded, and drains left running past the return are
/// abandoned: their buffers are snapshotted and every later chunk is
/// discarded, so a still-writing descendant cannot grow memory behind the
/// caller's back.
enum ProcessRunner {
    /// Accumulates drained chunks across threads (Swift 6 strict concurrency
    /// forbids capturing plain `var`s across threads). Internal rather than
    /// private so the abandonment contract stays unit-testable.
    final class LockedBuffer: @unchecked Sendable {
        private var data = Data()
        private var abandoned = false
        private let lock = NSLock()

        func append(_ chunk: Data) {
            lock.lock()
            if !abandoned {
                data.append(chunk)
            }
            lock.unlock()
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }

        /// Atomically snapshots everything captured so far, empties the
        /// buffer, and turns every later `append` into a discard. Called when
        /// the drain threads are left running past the owner's return, so a
        /// descendant still writing to an inherited pipe cannot accumulate
        /// data nobody will ever read.
        func abandon() -> Data {
            lock.lock()
            defer { lock.unlock() }
            abandoned = true
            let snapshot = data
            data = Data()
            return snapshot
        }
    }

    /// Spawn failures (executable missing) are rethrown so each call site
    /// keeps its existing "tool not found" handling.
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        let deadline = Date(timeIntervalSinceNow: timeout)

        let outBuffer = LockedBuffer()
        let errBuffer = LockedBuffer()
        let drains = DispatchGroup()
        drain(outPipe.fileHandleForReading, into: outBuffer, group: drains)
        drain(errPipe.fileHandleForReading, into: errBuffer, group: drains)

        var timedOut = !ProcessWait.waitForExit(process, timeout: timeout)
        if timedOut {
            forceExit(process)
        }

        // Timeout path: the child is dead and reaped, so the drains get only a
        // token grace. Normal exit: wait for EOF within the remaining budget,
        // which guarantees complete output; EOF that never comes means a
        // descendant is holding the pipes open and completeness cannot be
        // proven, so that is reported as a timeout too — never as a clean run
        // with silently truncated output.
        let grace = timedOut ? 0.25 : max(0, deadline.timeIntervalSinceNow)
        let drained = drains.wait(timeout: .now() + grace) == .success
        if !drained {
            timedOut = true
        }

        let stdout: Data
        let stderr: Data
        if drained {
            stdout = outBuffer.value
            stderr = errBuffer.value
        } else {
            // The drain threads outlive this call for as long as a descendant
            // keeps a write end open; abandoning snapshots what was captured
            // and makes them discard every later chunk.
            stdout = outBuffer.abandon()
            stderr = errBuffer.abandon()
        }

        return ProcessOutput(
            status: exitStatus(of: process),
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    /// `terminationStatus` once corelibs observed the exit. On Linux corelibs
    /// can lag behind reality (its exit notification travels through a
    /// descriptor a descendant may hold open), so a clean exit status is
    /// peeked straight from the kernel instead; -1 only when the child is
    /// genuinely unfinished or was killed. One race needs explicit handling:
    /// corelibs can reap the zombie between the `isRunning` check and the
    /// peek, leaving a window where the peek says ECHILD while `isRunning` is
    /// still stale-true — returning -1 there misreports a finished child
    /// (observed as the validator treating a missing kitty as `.valid`). The
    /// reap having happened means the `isRunning` flip is imminent, so that
    /// one case gets a bounded wait for `terminationStatus`.
    private static func exitStatus(of process: Process) -> Int32 {
        if !process.isRunning { return process.terminationStatus }
        #if os(Linux)
        switch ProcessWait.peekExit(pid: process.processIdentifier) {
        case let .exited(status):
            return status
        case .reaped:
            let deadline = Date(timeIntervalSinceNow: 2)
            while process.isRunning, Date() < deadline { usleep(1_000) }
            if !process.isRunning { return process.terminationStatus }
        case .running, .signaled:
            break
        }
        #endif
        return -1
    }

    /// Reads in chunks so an abandoned drain keeps everything captured so far
    /// (an all-at-once read-to-EOF would return nothing until EOF). A dedicated
    /// thread, not a global-queue work item: dispatch can defer work items for
    /// seconds when every core is busy, and the drains must start immediately
    /// or a fast child's output is lost. Raw `read(2)` instead of
    /// `availableData`: on Linux, corelibs-foundation turns a read failure —
    /// including a plain EINTR — into a fatalError, so EINTR is retried here.
    /// The handle is never closed here (and is kept captured so the
    /// descriptor stays valid for the thread's lifetime): closing it while
    /// this thread blocks in `read` is a corelibs crash, and leaving it open
    /// merely holds the descriptor until the last writer exits.
    private static func drain(_ handle: FileHandle, into buffer: LockedBuffer, group: DispatchGroup) {
        group.enter()
        let thread = Thread {
            defer { group.leave() }
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = chunk.withUnsafeMutableBytes { raw in
                    read(handle.fileDescriptor, raw.baseAddress, raw.count)
                }
                if count > 0 {
                    buffer.append(Data(chunk[0..<count]))
                } else if count == 0 {
                    return
                } else if errno != EINTR {
                    return
                }
            }
        }
        thread.start()
    }

    /// SIGTERM first; SIGKILL — which cannot be ignored — if the child does
    /// not exit promptly. Always ends with a reap, so no zombie is left and
    /// `terminationStatus` is valid on return. The pid cannot have been reused
    /// while unreaped, so the kill targets the right process.
    private static func forceExit(_ process: Process) {
        process.terminate()
        if ProcessWait.waitForExit(process, timeout: 2) { return }
        kill(process.processIdentifier, SIGKILL)
        ProcessWait.waitForExit(process, timeout: 5)
    }
}
