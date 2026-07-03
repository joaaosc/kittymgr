import Foundation

/// `init`: create the managed layer and inject one guarded `include` block into
/// the user's `kitty.conf`. Idempotent, backup-before-edit, fully reversible.
public struct InitCommand {
    public let configDir: ConfigDir
    public let dryRun: Bool

    public init(configDir: ConfigDir, dryRun: Bool = false) {
        self.configDir = configDir
        self.dryRun = dryRun
    }

    /// Returns `true` when the run made changes, `false` on an idempotent no-op.
    @discardableResult
    public func run(log: (String) -> Void = { print($0) }) throws -> Bool {
        let layout = configDir.detectedLayout()
        if dryRun {
            return try preview(layout: layout, log: log)
        }

        switch layout {
        case .legacy:
            return try migrateLegacyLayout(log: log)
        case .mixed(let detail):
            throw ConfigLayoutError.mixed(detail)
        case .current, .absent:
            return try initializeCurrentLayout(log: log)
        }
    }

    private func initializeCurrentLayout(log: (String) -> Void) throws -> Bool {
        let fm = FileManager.default

        try fm.createDirectory(at: configDir.url, withIntermediateDirectories: true)
        try fm.createDirectory(at: configDir.managedDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configDir.activeConf.path) {
            try Data().write(to: configDir.activeConf)
        }
        try SamplePlugins.seed(into: configDir.pluginsDir)

        log("Config directory: \(configDir.url.path)")

        let confExists = fm.fileExists(atPath: configDir.kittyConf.path)
        let original = confExists
            ? try String(contentsOf: configDir.kittyConf, encoding: .utf8)
            : ""

        if Guard.containsCurrentInclude(in: original) {
            log("Managed block already present; nothing to do.")
            return false
        }

        var meta = Meta(createdConf: !confExists, backup: nil)
        if confExists {
            let backup = try ConfigStore.makeBackup(of: configDir.kittyConf, in: configDir.confBackupsDir)
            meta.backup = configDir.relativePath(of: backup)
            log("Backed up kitty.conf -> \(configDir.relativePath(of: backup))")
        }

        try ConfigStore.writeAtomically(Guard.insert(into: original), to: configDir.kittyConf)
        try ConfigStore.writeMeta(meta, to: configDir.metaFile)

        log(confExists
            ? "Injected managed include block into kitty.conf."
            : "Created kitty.conf with managed include block.")
        return true
    }

    private func migrateLegacyLayout(log: (String) -> Void) throws -> Bool {
        let fm = FileManager.default
        let confExists = fm.fileExists(atPath: configDir.kittyConf.path)
        let original = confExists
            ? try String(contentsOf: configDir.kittyConf, encoding: .utf8)
            : ""

        log("Legacy layout detected (managed/).")

        var meta = Meta(createdConf: !confExists, backup: nil)
        if confExists {
            let legacyBackup = try ConfigStore.makeBackup(of: configDir.kittyConf, in: configDir.legacyConfBackupsDir)
            let finalBackup = configDir.confBackupsDir.appendingPathComponent(legacyBackup.lastPathComponent)
            meta.backup = configDir.relativePath(of: finalBackup)
            log("Backed up kitty.conf -> \(configDir.relativePath(of: finalBackup))")
        }

        do {
            try fm.moveItem(at: configDir.legacyManagedDir, to: configDir.managedDir)
            log("Renamed managed/ -> kittymgr/.")
        } catch {
            throw ConfigLayoutError.migrationFailed(
                "could not rename managed/ to kittymgr/: \(error). If needed, restore manually with `mv kittymgr managed` before retrying."
            )
        }

        if fm.fileExists(atPath: configDir.legacyLockFile.path) {
            guard !fm.fileExists(atPath: configDir.lockFile.path) else {
                throw ConfigLayoutError.migrationFailed(
                    "both kittymgr.lock and kittymgr/kittymgr.lock exist after directory migration; keep one lockfile, then rerun `kittymgr init`."
                )
            }
            do {
                try fm.moveItem(at: configDir.legacyLockFile, to: configDir.lockFile)
                log("Moved kittymgr.lock -> kittymgr/kittymgr.lock.")
            } catch {
                throw ConfigLayoutError.migrationFailed(
                    "could not move kittymgr.lock to kittymgr/kittymgr.lock: \(error). The anchor was not rewritten; move kittymgr/ back to managed/ or move the lock manually before retrying."
                )
            }
        }

        if !fm.fileExists(atPath: configDir.activeConf.path) {
            try Data().write(to: configDir.activeConf)
        }
        try SamplePlugins.seed(into: configDir.pluginsDir)

        let migrated = Guard.insert(into: Guard.remove(from: original))
        try ConfigStore.writeAtomically(migrated, to: configDir.kittyConf)
        try ConfigStore.writeMeta(meta, to: configDir.metaFile)
        log("Updated kitty.conf anchor to \(Guard.includeLine).")

        let snapshot = try SnapshotStore(configDir: configDir).create(label: "post-migration")
        log("Created post-migration snapshot \(snapshot.id).")
        return true
    }

    private func preview(layout: ConfigLayout, log: (String) -> Void) throws -> Bool {
        switch layout {
        case .mixed(let detail):
            throw ConfigLayoutError.mixed(detail)
        case .legacy:
            let original = (try? String(contentsOf: configDir.kittyConf, encoding: .utf8)) ?? ""
            let migrated = Guard.insert(into: Guard.remove(from: original))
            let diff = UnifiedDiff.diffStates(
                old: ["kitty.conf": original],
                new: ["kitty.conf": migrated]
            )
            log("Legacy layout detected (managed/).")
            log("[dry-run] What would change:")
            log("- managed/ -> kittymgr/ (atomic rename)")
            log("- kittymgr.lock -> kittymgr/kittymgr.lock")
            log("- kitty.conf backup -> kittymgr/backups/conf/kitty.conf.bak.<timestamp>")
            log("- kitty.conf anchor -> '\(Guard.includeLine)'")
            if !diff.isEmpty {
                log("[dry-run] Anchor diff:\n\(diff)")
            }
            return true
        case .current:
            let original = (try? String(contentsOf: configDir.kittyConf, encoding: .utf8)) ?? ""
            if Guard.containsCurrentInclude(in: original) {
                log("[dry-run] Managed block already present; nothing to do.")
                return false
            }
            let proposed = Guard.insert(into: original)
            let diff = UnifiedDiff.diffStates(old: ["kitty.conf": original], new: ["kitty.conf": proposed])
            log("[dry-run] Would update kitty.conf with '\(Guard.includeLine)'.")
            if !diff.isEmpty { log(diff) }
            return true
        case .absent:
            log("[dry-run] Would create kittymgr/, kittymgr/active.conf, and a kitty.conf anchor for '\(Guard.includeLine)'.")
            return true
        }
    }
}
