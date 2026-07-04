import Foundation

/// Outcome of attempting a live kitty configuration reload.
public enum ReloadOutcome: Sendable, Equatable {
    /// A running kitty reloaded its configuration.
    case reloaded
    /// Remote control is unavailable; the switch is persisted but the user must
    /// reload manually. `reason` explains why.
    case unavailable(reason: String)
}

/// Triggers a live kitty configuration reload.
public protocol Reloading {
    func reload() -> ReloadOutcome
}

/// Reloads via kitty remote control (`kitten @ load-config`, falling back to
/// `kitty @ load-config`). Detects at runtime whether remote control is available
/// and degrades gracefully when it is not.
public struct KittenReloader: Reloading {
    public init() {}

    public func reload() -> ReloadOutcome {
        var lastReason = "kitty remote control tools (kitten/kitty) not found."
        for tool in ["kitten", "kitty"] {
            switch run(tool: tool) {
            case .reloaded:
                return .reloaded
            case .notFound:
                continue
            case let .failed(reason):
                lastReason = reason
            }
        }
        return .unavailable(reason: lastReason)
    }

    private enum Attempt {
        case reloaded
        case notFound
        case failed(reason: String)
    }

    /// Wall-clock budget for `@ load-config`; a healthy kitty answers fast.
    private static let timeout: TimeInterval = 10

    private func run(tool: String) -> Attempt {
        let result: ProcessOutput
        do {
            result = try ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: [tool, "@", "load-config"],
                timeout: Self.timeout
            )
        } catch {
            return .notFound
        }
        if result.timedOut {
            return .failed(reason: "kitty remote control did not respond within \(Self.timeout)s.")
        }

        switch result.status {
        case 0:
            return .reloaded
        case 127:
            // `env` could not locate the tool.
            return .notFound
        default:
            let message = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(reason: message.isEmpty
                ? "remote control unavailable (exit \(result.status))."
                : message)
        }
    }
}
