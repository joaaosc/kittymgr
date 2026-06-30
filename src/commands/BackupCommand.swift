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

    public init(action: Action, configDir: ConfigDir, dryRun: Bool = false) {
        self.action = action
        self.store = SnapshotStore(configDir: configDir)
        self.dryRun = dryRun
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
        try store.restore(manifest)
        log("Restored snapshot \(manifest.id).")
    }
}
