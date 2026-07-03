import Foundation

/// `uninstall`: remove only the guarded block, restoring `kitty.conf` to its
/// pre-`init` state. When `init` created the file, it is removed entirely.
public struct UninstallCommand {
    public let configDir: ConfigDir
    public let removeManaged: Bool

    public init(configDir: ConfigDir, removeManaged: Bool = false) {
        self.configDir = configDir
        self.removeManaged = removeManaged
    }

    @discardableResult
    public func run(log: (String) -> Void = { print($0) }) throws -> Bool {
        let fm = FileManager.default
        let meta = ConfigStore.readMeta(from: configDir.metaFile)
            ?? Meta(createdConf: false, backup: nil)

        if fm.fileExists(atPath: configDir.kittyConf.path) {
            let content = try String(contentsOf: configDir.kittyConf, encoding: .utf8)
            if Guard.contains(in: content) {
                let cleaned = Guard.remove(from: content)
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
        return true
    }
}
