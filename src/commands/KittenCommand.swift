import Foundation

/// `kitten list | install <name> --from <path> | remove <name>`: manage kittens
/// (executable scripts) in isolated managed directories.
///
/// Kittens are kitty's own term for scripts run with `kitty +kitten`. They are
/// distinct from kittymgr's config-snippet `plugin`s: a kitten is code, never a
/// composed `.conf`, so it is *not* added to `active.conf` and is never executed by
/// kittymgr. Installation only copies files; the user invokes a kitten explicitly.
///
/// Every install/remove takes a snapshot first, so the managed history records what
/// third-party code entered the configuration and when, and the change is
/// reversible via `backup restore`.
public struct KittenCommand {
    public enum Action: Equatable {
        case list
        case install(name: String, source: String)
        case remove(name: String)
    }

    public let action: Action
    public let configDir: ConfigDir
    public let dryRun: Bool

    public init(action: Action, configDir: ConfigDir, dryRun: Bool = false) {
        self.action = action
        self.configDir = configDir
        self.dryRun = dryRun
    }

    public func run(log: (String) -> Void = { print($0) }) throws {
        let store = KittenStore(root: configDir.kittensDir)
        switch action {
        case .list:
            list(store, log: log)
        case let .install(name, source):
            try install(name: name, source: source, store: store, log: log)
        case let .remove(name):
            try remove(name: name, store: store, log: log)
        }
    }

    private func list(_ store: KittenStore, log: (String) -> Void) {
        let kittens = store.list()
        guard !kittens.isEmpty else {
            log("No kittens installed under managed/kittens/.")
            return
        }
        for kitten in kittens {
            let entry = kitten.entry.map { " — invoke: kitty +kitten managed/kittens/\(kitten.name)/\($0)" } ?? ""
            log("\(kitten.name)\(entry)")
        }
    }

    private func install(name rawName: String, source: String, store: KittenStore, log: (String) -> Void) throws {
        let name = try PluginName(validating: rawName)
        let sourceURL = URL(fileURLWithPath: source)

        if dryRun {
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw KittenError.sourceMissing(source)
            }
            guard !store.exists(name) else { throw KittenError.alreadyInstalled(name.value) }
            log("[dry-run] Would install kitten '\(name.value)' from \(source) into managed/kittens/\(name.value)/.")
            return
        }

        // Snapshot first: records the pre-install state for audit and rollback.
        try snapshot(label: "kitten-install-\(name.value)")
        let manifest = try store.install(name, from: sourceURL)
        log("Installed kitten '\(name.value)'. Not executed; invoke explicitly with kitty +kitten.")
        if let entry = manifest.entry {
            log("  kitty +kitten managed/kittens/\(name.value)/\(entry)")
        }
    }

    private func remove(name rawName: String, store: KittenStore, log: (String) -> Void) throws {
        let name = try PluginName(validating: rawName)

        if dryRun {
            guard store.exists(name) else { throw KittenError.notFound(name.value) }
            log("[dry-run] Would remove kitten '\(name.value)' and all its files.")
            return
        }

        try snapshot(label: "kitten-remove-\(name.value)")
        try store.remove(name)
        log("Removed kitten '\(name.value)'. Configuration left clean.")
    }

    private func snapshot(label: String) throws {
        try SnapshotStore(configDir: configDir).create(label: label)
    }
}
