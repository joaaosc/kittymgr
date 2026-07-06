#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

import Foundation

/// Minimal ANSI styling for CLI output. Basic 16-color palette plus bold/dim —
/// the baseline every color terminal renders, with no 256-color or truecolor
/// dependency. Styling is on whenever the stream is a TTY; a pipe gets plain
/// text so scripts never see escape codes, and `NO_COLOR` (any value) opts out.
public enum ConsoleStyle {
    /// Whether stdout gets styled text. Computed once per process.
    public static let stdoutStyled: Bool =
        isatty(STDOUT_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    /// Whether stderr gets styled text. Computed once per process.
    public static let stderrStyled: Bool =
        isatty(STDERR_FILENO) == 1 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    public static func bold(_ text: String) -> String { paint(text, code: "1", enabled: stdoutStyled) }
    public static func dim(_ text: String) -> String { paint(text, code: "2", enabled: stdoutStyled) }
    public static func green(_ text: String) -> String { paint(text, code: "32", enabled: stdoutStyled) }
    public static func cyan(_ text: String) -> String { paint(text, code: "36", enabled: stdoutStyled) }
    public static func yellow(_ text: String) -> String { paint(text, code: "33", enabled: stdoutStyled) }

    /// Red + bold, for stderr error prefixes.
    public static func errorLabel(_ text: String) -> String {
        paint(text, code: "31;1", enabled: stderrStyled)
    }

    static func paint(_ text: String, code: String, enabled: Bool) -> String {
        enabled ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
    }
}
