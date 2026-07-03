#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

import Foundation

public enum TerminalError: Error, CustomStringConvertible {
    case failedToGetAttributes
    case failedToSetAttributes
    case nonInteractive

    public var description: String {
        switch self {
        case .failedToGetAttributes:
            return "failed to read terminal attributes"
        case .failedToSetAttributes:
            return "failed to update terminal attributes"
        case .nonInteractive:
            return "kittymgr ui requires an interactive TTY. Use the CLI preview path instead, for example `kittymgr switch <profile> --dry-run`, `kittymgr sync --dry-run`, or `kittymgr backup restore <id> --dry-run`."
        }
    }
}

public protocol TerminalControlling: AnyObject {
    var isInteractive: Bool { get }
    func getSize() -> (rows: Int, cols: Int)
    func enableRawMode() throws
    func disableRawMode()
}

public final class Terminal: TerminalControlling {
    private var originalTermios = termios()
    private var isRaw = false

    public init() {}

    public var isInteractive: Bool {
        isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
    }

    public static func getSize() -> (rows: Int, cols: Int) {
        var w = winsize()
        #if os(macOS)
        let tiocgwinsz = UInt(Darwin.TIOCGWINSZ)
        #else
        let tiocgwinsz = UInt(0x5413) // TIOCGWINSZ on Linux
        #endif
        
        if ioctl(STDOUT_FILENO, tiocgwinsz, &w) == 0 {
            return (Int(w.ws_row), Int(w.ws_col))
        }
        return (24, 80)
    }

    public func getSize() -> (rows: Int, cols: Int) {
        Self.getSize()
    }

    public func enableRawMode() throws {
        guard !isRaw else { return }
        guard isInteractive else { throw TerminalError.nonInteractive }

        guard tcgetattr(STDIN_FILENO, &originalTermios) == 0 else {
            throw TerminalError.failedToGetAttributes
        }

        var raw = originalTermios
        // Disable ICANON (canonical mode), ECHO (echoing), and ISIG (Ctrl-C/Ctrl-Z signals)
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)

        // Set raw input read parameters (VMIN and VTIME)
        #if os(macOS)
        raw.c_cc.16 = 1 // VMIN
        raw.c_cc.17 = 0 // VTIME
        #else
        raw.c_cc[Int(VMIN)] = 1
        raw.c_cc[Int(VTIME)] = 0
        #endif

        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
            throw TerminalError.failedToSetAttributes
        }

        isRaw = true
        TerminalSignalState.activate(originalTermios)

        // Enter alternate screen buffer and hide cursor
        print("\u{001B}[?1049h", terminator: "")
        print("\u{001B}[?25l", terminator: "")
        fflush(stdout)
    }

    public func disableRawMode() {
        guard isRaw else { return }

        // Exit alternate screen buffer and show cursor
        print("\u{001B}[?25h", terminator: "")
        print("\u{001B}[?1049l", terminator: "")
        fflush(stdout)

        _ = tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
        isRaw = false
        TerminalSignalState.deactivate()
    }

    deinit {
        disableRawMode()
    }
}

private enum TerminalSignalState {
    nonisolated(unsafe) private static var originalTermios = termios()
    nonisolated(unsafe) private static var active = false
    nonisolated(unsafe) private static var installed = false
    private static let restoreSequence: [UInt8] = [
        0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68, // show cursor
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x6C, // leave alternate screen
    ]

    private static let handler: @convention(c) (Int32) -> Void = { signalNumber in
        restoreTerminal()
        #if os(macOS)
        Darwin.signal(signalNumber, SIG_DFL)
        Darwin.raise(signalNumber)
        #else
        Glibc.signal(signalNumber, SIG_DFL)
        Glibc.raise(signalNumber)
        #endif
    }

    static func activate(_ termios: termios) {
        originalTermios = termios
        active = true
        installIfNeeded()
    }

    static func deactivate() {
        active = false
    }

    private static func installIfNeeded() {
        guard !installed else { return }
        #if os(macOS)
        Darwin.signal(SIGINT, handler)
        Darwin.signal(SIGTERM, handler)
        #else
        Glibc.signal(SIGINT, handler)
        Glibc.signal(SIGTERM, handler)
        #endif
        installed = true
    }

    private static func restoreTerminal() {
        guard active else { return }
        var saved = originalTermios
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &saved)
        restoreSequence.withUnsafeBufferPointer { buffer in
            _ = write(STDOUT_FILENO, buffer.baseAddress, buffer.count)
        }
        active = false
    }
}
