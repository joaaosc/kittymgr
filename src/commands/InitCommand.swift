import Foundation

/// `init`: create the managed layer and inject one guarded `include` block into
/// the user's `kitty.conf`. Idempotent, backup-before-edit, fully reversible.
public struct InitCommand {
    public let configDir: ConfigDir

    public init(configDir: ConfigDir) {
        self.configDir = configDir
    }

    /// Returns `true` when the run made changes, `false` on an idempotent no-op.
    @discardableResult
    public func run(log: (String) -> Void = { print($0) }) throws -> Bool {
        let fm = FileManager.default

        try fm.createDirectory(at: configDir.url, withIntermediateDirectories: true)
        try fm.createDirectory(at: configDir.managedDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: configDir.activeConf.path) {
            try Data().write(to: configDir.activeConf)
        }

        log("Config directory: \(configDir.url.path)")

        let confExists = fm.fileExists(atPath: configDir.kittyConf.path)
        let original = confExists
            ? try String(contentsOf: configDir.kittyConf, encoding: .utf8)
            : ""

        if Guard.contains(in: original) {
            log("Managed block already present; nothing to do.")
            return false
        }

        var meta = Meta(createdConf: !confExists, addedTrailingNewline: false, backup: nil)
        if confExists {
            let backup = try ConfigStore.makeBackup(of: configDir.kittyConf)
            meta.backup = backup.lastPathComponent
            log("Backed up kitty.conf -> \(backup.lastPathComponent)")
        }

        let appended = Guard.append(to: original)
        meta.addedTrailingNewline = appended.addedTrailingNewline
        try ConfigStore.writeAtomically(appended.content, to: configDir.kittyConf)
        try ConfigStore.writeMeta(meta, to: configDir.metaFile)

        log(confExists
            ? "Injected managed include block into kitty.conf."
            : "Created kitty.conf with managed include block.")
        return true
    }
}
