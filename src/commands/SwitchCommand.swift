import Foundation

/// `switch <name> [--force] [--dry-run]`: compose the selected profile and make it
/// active through the transactional apply pipeline.
///
/// Conflicts are detected up front and gate the switch: an unresolved conflict
/// blocks unless `--force` is given (conflicts are still printed). The change then
/// flows through `ApplyTransaction` — snapshot → atomic write of `active.conf` →
/// validate → reload, rolling back to the pre-apply snapshot if validation fails.
/// The active pointer is moved only after the apply is kept, so a rejected switch
/// leaves the previous selection intact. `--dry-run` previews the diff and writes
/// nothing.
public struct SwitchCommand {
    public let profileStore: ProfileStore
    public let pluginStore: PluginStore
    public let activePointer: ActivePointer
    public let activeConf: URL
    public let rawName: String
    public let force: Bool
    public let dryRun: Bool
    public let validator: any ConfigValidating
    public let reloader: any Reloading

    public init(
        profileStore: ProfileStore,
        pluginStore: PluginStore,
        activePointer: ActivePointer,
        activeConf: URL,
        rawName: String,
        force: Bool = false,
        dryRun: Bool = false,
        validator: any ConfigValidating = KittyConfigValidator(),
        reloader: any Reloading = KittenReloader()
    ) {
        self.profileStore = profileStore
        self.pluginStore = pluginStore
        self.activePointer = activePointer
        self.activeConf = activeConf
        self.rawName = rawName
        self.force = force
        self.dryRun = dryRun
        self.validator = validator
        self.reloader = reloader
    }

    public func run(log: (String) -> Void = { print($0) }) throws {
        let name = try profileStore.resolveName(ProfileName(validating: rawName))
        guard profileStore.exists(name) else {
            throw ProfileError.notFound(name.value)
        }

        // `active.conf` is canonically `<configDir>/managed/active.conf`; recover
        // the config root so the transaction can snapshot the whole managed surface.
        let configDir = ConfigDir(url: activeConf.deletingLastPathComponent().deletingLastPathComponent())

        let composed = try ProfileComposer.compose(
            profile: name,
            configDir: configDir,
            profileStore: profileStore,
            pluginStore: pluginStore
        )

        // Conflict gate (pre-write): block unless forced.
        if !composed.conflicts.isEmpty {
            for conflict in composed.conflicts {
                log("warning: \(conflict.message)")
            }
            if !force {
                throw SafetyError.unresolvedConflicts(composed.conflicts.count)
            }
            log("Proceeding despite conflicts (--force).")
        }

        let transaction = ApplyTransaction(
            snapshotStore: SnapshotStore(configDir: configDir),
            validator: validator,
            reloader: reloader
        )
        let result = try transaction.apply(
            plan: composed.plan,
            validationContent: composed.validationContent,
            dryRun: dryRun,
            log: log
        )

        guard result.status == .applied else { return }  // dry-run: nothing to record
        try activePointer.set(name)
        log("Switched to '\(name.value)'.")
    }
}
