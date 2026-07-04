#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// Portable stdout flushing for the TUI.
///
/// Glibc exposes `stdout` as a mutable global that Swift 6 rejects as
/// concurrency-unsafe shared state, so the Linux path flushes via
/// `fflush(nil)` (POSIX: flushes every open output stream) instead of
/// referencing the global. Darwin keeps the direct call.
public enum TerminalIO {
    public static func flushStdout() {
        #if os(macOS)
        fflush(stdout)
        #else
        fflush(nil)
        #endif
    }
}
