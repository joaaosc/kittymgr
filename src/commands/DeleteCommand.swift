import Foundation

/// `delete <name> [--force]`: remove a profile directory.
///
/// Without `--force`, deletion goes through `confirm`, which the CLI wires to an
/// interactive stdin prompt.
public struct DeleteCommand {
    public let store: ProfileStore
    public let rawName: String
    public let force: Bool
    public let confirm: (String) -> Bool

    public init(
        store: ProfileStore,
        rawName: String,
        force: Bool = false,
        confirm: @escaping (String) -> Bool = { _ in false }
    ) {
        self.store = store
        self.rawName = rawName
        self.force = force
        self.confirm = confirm
    }

    public func run(log: (String) -> Void = { print($0) }) throws {
        let name = try ProfileName(validating: rawName)
        guard store.exists(name) else {
            throw ProfileError.notFound(name.value)
        }
        if !force, !confirm("Delete profile '\(name.value)'? [y/N] ") {
            log("Aborted; '\(name.value)' was not deleted.")
            return
        }
        try store.delete(name)
        log("Deleted profile '\(name.value)'.")
    }
}
