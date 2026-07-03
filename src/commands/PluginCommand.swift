import Foundation

/// `plugin list | enable <name> | disable <name>`: manage which plugins are
/// enabled for a profile.
///
/// Enable/disable state is per-profile (stored in the profile's metadata), so the
/// same plugin can be on for one profile and off for another. When the change
/// targets the active profile, `active.conf` is regenerated and kitty reloaded so
/// the effect (or its removal) applies immediately.
public struct PluginCommand {
    public enum Action: Equatable {
        case list
        case enable(String)
        case disable(String)
    }

    public let action: Action
    public let profileStore: ProfileStore
    public let pluginStore: PluginStore
    public let activePointer: ActivePointer
    public let activeConf: URL
    /// Explicit `--profile`; when nil the active profile is used.
    public let profileOverride: String?
    public let dryRun: Bool
    public let validator: any ConfigValidating
    public let reloader: any Reloading

    public init(
        action: Action,
        profileStore: ProfileStore,
        pluginStore: PluginStore,
        activePointer: ActivePointer,
        activeConf: URL,
        profileOverride: String? = nil,
        dryRun: Bool = false,
        validator: any ConfigValidating = KittyConfigValidator(),
        reloader: any Reloading = KittenReloader()
    ) {
        self.action = action
        self.profileStore = profileStore
        self.pluginStore = pluginStore
        self.activePointer = activePointer
        self.activeConf = activeConf
        self.profileOverride = profileOverride
        self.dryRun = dryRun
        self.validator = validator
        self.reloader = reloader
    }

    public func run(log: (String) -> Void = { print($0) }) throws {
        switch action {
        case .list:
            try runList(log: log)
        case let .enable(name):
            try runToggle(pluginRaw: name, enable: true, log: log)
        case let .disable(name):
            try runToggle(pluginRaw: name, enable: false, log: log)
        }
    }

    // MARK: - list

    private func runList(log: (String) -> Void) throws {
        let plugins = try pluginStore.list()
        if plugins.isEmpty {
            log("No plugins available under kittymgr/plugins/.")
            return
        }
        let context = try? resolveProfile()
        let enabled = context.map { Set(profileStore.metadata(for: $0).enabledPlugins) } ?? []
        if let context {
            log("Plugins for profile '\(context.value)':")
        } else {
            log("Available plugins (no active profile; pass --profile <name> for state):")
        }
        for plugin in plugins {
            let mark = enabled.contains(plugin.name) ? "[x]" : "[ ]"
            log("\(mark) \(plugin.name)")
        }
    }

    // MARK: - enable / disable

    private func runToggle(pluginRaw: String, enable: Bool, log: (String) -> Void) throws {
        let plugin = try PluginName(validating: pluginRaw)
        guard pluginStore.exists(plugin) else {
            throw ProfileError.notFound(plugin.value)
        }
        let profile = try resolveProfile()

        var metadata = profileStore.metadata(for: profile)
        var enabledPlugins = metadata.enabledPlugins
        let alreadyEnabled = enabledPlugins.contains(plugin.value)

        if enable {
            guard !alreadyEnabled else {
                log("Plugin '\(plugin.value)' already enabled for '\(profile.value)'.")
                return
            }
            enabledPlugins.append(plugin.value)
        } else {
            guard alreadyEnabled else {
                log("Plugin '\(plugin.value)' is not enabled for '\(profile.value)'.")
                return
            }
            enabledPlugins.removeAll { $0 == plugin.value }
        }

        metadata.enabledPlugins = enabledPlugins

        let configDir = ConfigDir(url: activeConf.deletingLastPathComponent().deletingLastPathComponent())
        var plan = ApplyPlan(
            writes: [
                configDir.relativePath(of: profileStore.metadataURL(for: profile)): try encodedMetadata(metadata)
            ]
        )
        var validationContent = ""
        let shouldReload = activePointer.get() == profile.value

        if shouldReload {
            let composed = try ProfileComposer.compose(
                profile: profile,
                configDir: configDir,
                profileStore: profileStore,
                pluginStore: pluginStore,
                enabledPluginsOverride: enabledPlugins
            )
            for (path, content) in composed.plan.writes {
                plan.writes[path] = content
            }
            plan.deletes.append(contentsOf: composed.plan.deletes)
            validationContent = composed.validationContent
        }

        let result = try ApplyTransaction(
            snapshotStore: SnapshotStore(configDir: configDir),
            validator: validator,
            reloader: reloader
        ).apply(
            plan: plan,
            validationContent: validationContent,
            dryRun: dryRun,
            reload: shouldReload,
            log: log
        )

        guard result.status == .applied else { return }
        if let snapshotID = result.snapshotID {
            log("Snapshot pre-apply: \(snapshotID).")
        }
        log("\(enable ? "Enabled" : "Disabled") plugin '\(plugin.value)' for '\(profile.value)'.")
    }

    // MARK: - helpers

    private func resolveProfile() throws -> ProfileName {
        if let profileOverride {
            let name = try ProfileName(validating: profileOverride)
            guard profileStore.exists(name) else { throw ProfileError.notFound(name.value) }
            return name
        }
        guard let active = activePointer.get() else {
            throw ProfileError.noActiveProfile
        }
        return try ProfileName(validating: active)
    }

    private func encodedMetadata(_ metadata: ProfileMetadata) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        return String(decoding: data, as: UTF8.self)
    }
}
