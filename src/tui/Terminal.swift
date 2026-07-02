#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

import Foundation

public enum TerminalError: Error {
    case failedToGetAttributes
    case failedToSetAttributes
}

public final class Terminal {
    private var originalTermios = termios()
    private var isRaw = false

    public init() {}

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

    public func enableRawMode() throws {
        guard !isRaw else { return }

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
    }

    deinit {
        disableRawMode()
    }
}
