import Foundation

/// `create <name>`: create an empty profile directory.
///
/// New profiles are intentionally empty; users add `.conf` snippets to them. An
/// empty profile is valid and resolves to no managed settings.
public struct CreateCommand {
    public let store: ProfileStore
    public let rawName: String

    public init(store: ProfileStore, rawName: String) {
        self.store = store
        self.rawName = rawName
    }

    public func run(log: (String) -> Void = { print($0) }) throws {
        let name = try ProfileName(validating: rawName)
        try store.create(name)
        log("Created profile '\(name.value)'.")
    }
}
