import Foundation

/// A validated, filesystem-portable plugin name. Same rules as `ProfileName`.
public struct PluginName: Sendable, Equatable {
    public let value: String

    public init(validating raw: String) throws {
        self.value = try ManagedName.validate(raw)
    }
}

/// A plugin discovered under `kittymgr/plugins/<name>/`.
///
/// `priority` orders plugins within the generated include: lower priority is
/// included earlier, so higher-priority plugins win for overlapping options
/// (kitty is last-wins). The lexical name breaks ties.
public struct Plugin: Sendable, Equatable {
    public let name: String
    public let priority: Int

    public init(name: String, priority: Int) {
        self.name = name
        self.priority = priority
    }

    /// Deterministic ordering: by priority ascending, then name lexically.
    public static func order(_ lhs: Plugin, _ rhs: Plugin) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        return lhs.name < rhs.name
    }
}
