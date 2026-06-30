import Foundation

/// Errors surfaced by profile and plugin operations. `description` is safe to print directly.
public enum ProfileError: Error, CustomStringConvertible, Equatable {
    case invalidName(String, reason: String)
    case alreadyExists(String)
    case notFound(String)
    case unsafePath(String)
    case noActiveProfile

    public var description: String {
        switch self {
        case let .invalidName(name, reason):
            return "invalid name '\(name)': \(reason)"
        case let .alreadyExists(name):
            return "'\(name)' already exists"
        case let .notFound(name):
            return "'\(name)' not found"
        case let .unsafePath(name):
            return "refusing to operate on '\(name)': resolved path escapes the managed directory"
        case .noActiveProfile:
            return "no active profile; switch to one or pass --profile <name>"
        }
    }
}

/// Shared validation for filesystem-portable managed names (profiles and plugins).
enum ManagedName {
    static let allowed: Set<Character> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )
    static let maxLength = 255

    /// Validates `raw`, returning it unchanged, or throws `ProfileError.invalidName`.
    static func validate(_ raw: String) throws -> String {
        guard !raw.isEmpty else {
            throw ProfileError.invalidName(raw, reason: "name is empty")
        }
        guard raw.count <= maxLength else {
            throw ProfileError.invalidName(raw, reason: "name exceeds \(maxLength) characters")
        }
        guard !raw.hasPrefix(".") else {
            // Rejects ".", "..", and hidden names in one rule, keeping create and
            // list (which skips hidden entries) consistent.
            throw ProfileError.invalidName(raw, reason: "name must not start with '.'")
        }
        for character in raw where !allowed.contains(character) {
            throw ProfileError.invalidName(
                raw,
                reason: "contains disallowed character '\(character)'; allowed: A-Z a-z 0-9 . _ -"
            )
        }
        return raw
    }
}

/// A validated, filesystem-portable profile name.
///
/// Construction is the only way to obtain a name, so any value of this type is
/// guaranteed safe to join onto a path: no separators, no traversal, no hidden
/// or empty names.
public struct ProfileName: Sendable, Equatable {
    public let value: String

    public init(validating raw: String) throws {
        self.value = try ManagedName.validate(raw)
    }
}

/// Per-profile metadata persisted as `profile.json` inside the profile directory.
/// Optional: a bare folder of `.conf` files remains valid (decodes to defaults).
public struct ProfileMetadata: Codable, Equatable, Sendable {
    public var enabledPlugins: [String]

    public init(enabledPlugins: [String] = []) {
        self.enabledPlugins = enabledPlugins
    }
}
