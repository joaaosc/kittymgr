import Foundation

/// `uninstall [--purge] [--force]`: remove only the guarded block, restoring
/// `kitty.conf` to its pre-`init` state. When `init` created the file, it is
/// removed entirely. `--purge` also deletes the managed directory.
///
/// Without `force`, the run goes through `confirm` with a prompt that states
/// exactly what will be removed. The default auto-confirms so programmatic
/// callers keep explicit-invocation semantics; the CLI wires an interactive
/// stdin prompt plus a non-TTY gate.
public struct UninstallCommand {
    public let configDir: ConfigDir
    public let removeManaged: Bool
    public let force: Bool
    public let confirm: (String) -> Bool

    public init(
        configDir: ConfigDir,
        removeManaged: Bool = false,
        force: Bool = false,
        confirm: @escaping (String) -> Bool = { _ in true }
    ) {
        self.configDir = configDir
        self.removeManaged = removeManaged
        self.force = force
        self.confirm = confirm
    }

    @discardableResult
    public func run(log: (String) -> Void = { print($0) }) throws -> Bool {
        if !force, !confirm(prompt()) {
            log("Aborted; nothing was changed.")
            return false
        }

        let fm = FileManager.default
        let meta = ConfigStore.readMeta(from: configDir.metaFile)
            ?? Meta(createdConf: false, backup: nil)

        if fm.fileExists(atPath: configDir.kittyConf.path) {
            let content = try String(contentsOf: configDir.kittyConf, encoding: .utf8)
            if try Guard.state(of: content).hasBlock {
                let cleaned = try Guard.remove(from: content)
                let isEmptyNow = cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if meta.createdConf, isEmptyNow {
                    try fm.removeItem(at: configDir.kittyConf)
                    log("Removed tool-created kitty.conf.")
                } else {
                    try ConfigStore.writeAtomically(cleaned, to: configDir.kittyConf)
                    log("Removed managed block from kitty.conf.")
                }
            } else {
                log("No managed block found in kitty.conf.")
            }
        } else {
            log("kitty.conf not found; nothing to remove.")
        }

        try? fm.removeItem(at: configDir.metaFile)

        if removeManaged {
            try? fm.removeItem(at: configDir.managedDir)
            log("Removed kittymgr directory.")
        }
        log("kitty.conf is back under your full control. Reinstall anytime with `kittymgr init`.")
        return true
    }

    /// States exactly what this run will remove.
    private func prompt() -> String {
        if removeManaged {
            let profiles = ((try? ProfileStore(root: configDir.profilesDir).list()) ?? []).count
            let snapshots = SnapshotStore(configDir: configDir).list().count
            return "Remove the kittymgr block from \(configDir.kittyConf.path) and permanently delete \(configDir.managedDir.path) (\(profiles) profile(s), \(snapshots) snapshot(s))? [y/N] "
        }
        return "Remove the kittymgr block from \(configDir.kittyConf.path)? Profiles and snapshots under \(configDir.managedDir.lastPathComponent)/ are kept. [y/N] "
    }
}
