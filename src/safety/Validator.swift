import Foundation

/// Outcome of validating a composed configuration against kitty's own parser.
public enum ValidationResult: Equatable, Sendable {
    case valid
    case invalid(diagnostics: String)
    /// The validator could not run (e.g. kitty not installed); not treated as a failure.
    case skipped(reason: String)
}

/// Validates a composed configuration. Injectable so commands can be tested
/// without invoking kitty.
public protocol ConfigValidating {
    func validate(content: String) -> ValidationResult
}

/// A malformed kittymgr anchor in kitty.conf. Commands surface this as a hard
/// safety error because silently rewriting a partial or edited block can discard
/// user-owned config.
public struct AnchorCorruption: Sendable, Equatable, CustomStringConvertible {
    public let detail: String
    public let line: Int
    public let repair: String

    public init(detail: String, line: Int, repair: String) {
        self.detail = detail
        self.line = line
        self.repair = repair
    }

    public var description: String {
        "corrupted kittymgr block in kitty.conf (\(detail) on line \(line)). Nothing was changed. \(repair)"
    }
}

/// Errors raised by the safety gate before activation.
public enum SafetyError: Error, CustomStringConvertible, Equatable {
    case invalidConfiguration(String)
    case unresolvedConflicts(Int)
    case corruptedAnchor(AnchorCorruption)

    public var description: String {
        switch self {
        case let .invalidConfiguration(diagnostics):
            return "composed configuration is invalid:\n\(diagnostics)"
        case let .unresolvedConflicts(count):
            return "\(count) unresolved conflict(s); re-run with --force to proceed"
        case let .corruptedAnchor(issue):
            return issue.description
        }
    }
}

/// Validates by writing the composed content to a temporary file and running
/// `kitty --config <file> --debug-config`, which parses the config and exits.
/// kitty-not-found or launch failure degrades to `.skipped` rather than blocking.
public struct KittyConfigValidator: ConfigValidating {
    public init() {}

    public func validate(content: String) -> ValidationResult {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kittymgr-validate-\(UUID().uuidString).conf")
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            return .skipped(reason: "could not stage temporary config")
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["kitty", "--config", tempURL.path, "--debug-config"]
        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = outputPipe

        do {
            try process.run()
        } catch {
            return .skipped(reason: "kitty not found")
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus == 127 {
            return .skipped(reason: "kitty not found")
        }

        let diagnostics = String(decoding: errorData, as: UTF8.self)
        let lowered = diagnostics.lowercased()

        // Older kitty versions lack `--debug-config`; don't treat our own
        // unsupported invocation as a config error — degrade to skipped.
        if mentionsUnsupportedInvocation(lowered) {
            return .skipped(reason: "this kitty version does not support config validation (--debug-config)")
        }
        if mentionsConfigError(lowered) {
            return .invalid(diagnostics: diagnostics.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .valid
    }

    private func mentionsUnsupportedInvocation(_ stderr: String) -> Bool {
        ["unknown flag", "unknown option", "unrecognized", "use --help"]
            .contains { stderr.contains($0) }
    }

    /// kitty reports config problems on stderr; match specific diagnostic markers
    /// rather than bare words to avoid false positives across versions.
    private func mentionsConfigError(_ stderr: String) -> Bool {
        ["bad value", "failed to parse", "error parsing", "is not a valid", "invalid value"]
            .contains { stderr.contains($0) }
    }
}
