import Foundation

/// `backup`: capture, list, and restore snapshots of the managed surface, with a
/// `--dry-run` preview that prints a unified diff instead of writing.
public struct BackupCommand {
    public enum Action: Equatable {
        case create(label: String?)
        case list
        case restore(id: String)
    }

    public let action: Action
    public let store: SnapshotStore
    public let dryRun: Bool
    public let force: Bool
    public let confirm: (String) -> Bool

    /// Without `force`, `restore` goes through `confirm` with a prompt naming
    /// the snapshot and how many files it overwrites. The default auto-confirms
    /// so programmatic callers keep explicit-invocation semantics; the CLI wires
    /// an interactive stdin prompt plus a non-TTY gate.
    public init(
        action: Action,
        configDir: ConfigDir,
        dryRun: Bool = false,
        force: Bool = false,
        confirm: @escaping (String) -> Bool = { _ in true }
    ) {
        self.action = action
        self.store = SnapshotStore(configDir: configDir)
        self.dryRun = dryRun
        self.force = force
        self.confirm = confirm
    }

    public func run(log: (String) -> Void = { print($0) }) throws {
        switch action {
        case .create(let label):
            try create(label: label, log: log)
        case .list:
            listSnapshots(log: log)
        case .restore(let id):
            try restore(id: id, log: log)
        }
    }

    private func create(label: String?, log: (String) -> Void) throws {
        if dryRun {
            let baseline = store.list().first.flatMap { try? store.contents(of: $0) } ?? [:]
            let diff = UnifiedDiff.diffStates(old: baseline, new: store.currentContents())
            log(diff.isEmpty
                ? "[dry-run] No changes since the last snapshot."
                : "[dry-run] Snapshot would capture:\n" + diff)
            return
        }
        let manifest = try store.create(label: label)
        log("Created snapshot \(manifest.id)" + (label.map { " (\($0))" } ?? "") + ".")
    }

    private func listSnapshots(log: (String) -> Void) {
        let snapshots = store.list()
        guard !snapshots.isEmpty else {
            log("No snapshots.")
            return
        }
        for snapshot in snapshots {
            log("\(snapshot.id)\t\(snapshot.createdAt)\t\(snapshot.label ?? "-")")
        }
    }

    private func restore(id: String, log: (String) -> Void) throws {
        guard let manifest = store.manifest(matching: id) else {
            throw BackupError.notFound(id)
        }
        if dryRun {
            let diff = UnifiedDiff.diffStates(old: store.currentContents(), new: try store.contents(of: manifest))
            log(diff.isEmpty
                ? "[dry-run] Restore \(manifest.id) would make no changes."
                : "[dry-run] Restore \(manifest.id) would apply:\n" + diff)
            return
        }
        if !force {
            let files = (try? store.contents(of: manifest).count) ?? 0
            let label = manifest.label.map { " ('\($0)')" } ?? ""
            let prompt = "Restore snapshot \(manifest.id)\(label) from \(manifest.createdAt), overwriting the current managed state (\(files) file(s))? [y/N] "
            guard confirm(prompt) else {
                log("Aborted; snapshot \(manifest.id) was not restored.")
                return
            }
        }
        // Reversibility: the restore itself must be undoable. Capture the current
        // state first, so restoring the wrong snapshot is a one-command recovery.
        let safety = try store.create(label: "pre-restore")
        try store.restore(manifest)
        log("Restored snapshot \(manifest.id).")
        log("Undo: `kittymgr backup restore \(safety.id)`")
    }
}
