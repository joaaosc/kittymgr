import Foundation

/// `switch <name> [--force]`: validate and compose the selected profile, record
/// it as active, then trigger a live reload.
///
/// The profile is validated and confirmed to exist before anything is written.
/// The composed configuration is then gated: an invalid configuration blocks the
/// switch; unresolved conflicts block unless `--force` is given (conflicts are
/// still printed). The atomic write, pointer update, and reload are delegated to
/// `Activator`.
public struct SwitchCommand {
    public let profileStore: ProfileStore
    public let pluginStore: PluginStore
    public let activePointer: ActivePointer
    public let activeConf: URL
    public let rawName: String
    public let force: Bool
    public let validator: any ConfigValidating
    public let reloader: any Reloading

    public init(
        profileStore: ProfileStore,
        pluginStore: PluginStore,
        activePointer: ActivePointer,
        activeConf: URL,
        rawName: String,
        force: Bool = false,
        validator: any ConfigValidating = KittyConfigValidator(),
        reloader: any Reloading = KittenReloader()
    ) {
        self.profileStore = profileStore
        self.pluginStore = pluginStore
        self.activePointer = activePointer
        self.activeConf = activeConf
        self.rawName = rawName
        self.force = force
        self.validator = validator
        self.reloader = reloader
    }

    public func run(log: (String) -> Void = { print($0) }) throws {
        let name = try ProfileName(validating: rawName)
        guard profileStore.exists(name) else {
            throw ProfileError.notFound(name.value)
        }

        let report = try SafetyGate.evaluate(
            profile: name,
            profileStore: profileStore,
            pluginStore: pluginStore,
            validator: validator
        )

        switch report.validation {
        case let .invalid(diagnostics):
            log("error: refusing to switch; composed configuration is invalid:")
            log(diagnostics)
            throw SafetyError.invalidConfiguration(diagnostics)
        case let .skipped(reason):
            log("Validation skipped (\(reason)).")
        case .valid:
            break
        }

        if !report.conflicts.isEmpty {
            for conflict in report.conflicts {
                log("warning: \(conflict.message)")
            }
            if !force {
                throw SafetyError.unresolvedConflicts(report.conflicts.count)
            }
            log("Proceeding despite conflicts (--force).")
        }

        let activator = Activator(
            profileStore: profileStore,
            pluginStore: pluginStore,
            activePointer: activePointer,
            activeConf: activeConf,
            reloader: reloader
        )
        log("Switched to '\(name.value)'.")
        try activator.activate(name, log: log)
    }
}
