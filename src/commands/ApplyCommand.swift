import Foundation

/// `apply [--dry-run]`: re-compose the active profile's `active.conf` and apply it
/// through the transactional pipeline (snapshot → write → validate → reload, with
/// rollback on a validation failure).
///
/// Useful after editing a profile's or plugin's `.conf` files by hand: it
/// re-materializes `active.conf` and confirms kitty still accepts the result,
/// reverting cleanly if it does not. This is the safe-apply primitive that the
/// composition features build on.
public struct ApplyCommand {
    public let configDir: ConfigDir
    public let profileStore: ProfileStore
    public let pluginStore: PluginStore
    public let activePointer: ActivePointer
    public let dryRun: Bool
    public let validator: any ConfigValidating
    public let reloader: any Reloading

    public init(
        configDir: ConfigDir,
        dryRun: Bool = false,
        validator: any ConfigValidating = KittyConfigValidator(),
        reloader: any Reloading = KittenReloader()
    ) {
        self.configDir = configDir
        self.profileStore = ProfileStore(root: configDir.profilesDir)
        self.pluginStore = PluginStore(root: configDir.pluginsDir)
        self.activePointer = ActivePointer(url: configDir.activePointerFile)
        self.dryRun = dryRun
        self.validator = validator
        self.reloader = reloader
    }

    public func run(log: (String) -> Void = { print($0) }) throws {
        guard let active = activePointer.get() else {
            throw ProfileError.noActiveProfile
        }
        let name = try ProfileName(validating: active)
        guard profileStore.exists(name) else {
            throw ProfileError.notFound(name.value)
        }

        let composed = try ProfileComposer.compose(
            profile: name,
            configDir: configDir,
            profileStore: profileStore,
            pluginStore: pluginStore
        )

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
        if result.status == .applied {
            log("Applied active profile '\(name.value)'.")
        }
    }
}
