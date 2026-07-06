import Foundation

/// `delete <name> [--force]`: remove a profile directory.
///
/// Without `--force`, deletion goes through `confirm`, which the CLI wires to an
/// interactive stdin prompt. When a `SnapshotStore` is provided (the CLI always
/// provides one), the managed surface is snapshotted first so a deleted profile
/// is a one-command restore away — profile contents are user-authored and must
/// never be lost irrecoverably.
public struct DeleteCommand {
    public let store: ProfileStore
    public let rawName: String
    public let force: Bool
    public let confirm: (String) -> Bool
    public let snapshots: SnapshotStore?

    public init(
        store: ProfileStore,
        rawName: String,
        force: Bool = false,
        confirm: @escaping (String) -> Bool = { _ in false },
        snapshots: SnapshotStore? = nil
    ) {
        self.store = store
        self.rawName = rawName
        self.force = force
        self.confirm = confirm
        self.snapshots = snapshots
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
        let safety = try snapshots?.create(label: "pre-delete")
        try store.delete(name)
        log("Deleted profile '\(name.value)'.")
        if let safety {
            log("Undo: `kittymgr backup restore \(safety.id)`")
        }
    }
}
