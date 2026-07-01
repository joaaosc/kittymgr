import Foundation

/// A profile composed into a ready-to-apply change: the `active.conf` write, the
/// inlined document for validation, and the detected conflicts. Shared by `switch`
/// and `apply` so both compose a profile identically.
struct ComposedApply {
    let plan: ApplyPlan
    let validationContent: String
    let conflicts: [Conflict]
}

enum ProfileComposer {
    /// Build the apply plan for making `name` the active profile: regenerate
    /// `active.conf` from the profile's base snippets, enabled plugins, and the
    /// active modular blocks; capture the inlined layers for validation; and detect
    /// conflicts across them.
    ///
    /// `blockChange`, when set, is a pending modular-block mutation folded into the
    /// composition so the resulting `active.conf` and the block file write/delete
    /// land in a single transactional plan.
    static func compose(
        profile name: ProfileName,
        configDir: ConfigDir,
        profileStore: ProfileStore,
        pluginStore: PluginStore,
        blockChange: BlockChange? = nil
    ) throws -> ComposedApply {
        let enabledPlugins = profileStore.metadata(for: name).enabledPlugins
        let profileIncludes = try IncludeBuilder.includes(
            profile: name,
            profileStore: profileStore,
            pluginStore: pluginStore,
            enabledPlugins: enabledPlugins
        )
        let profileLayers = try IncludeBuilder.layers(
            profile: name,
            profileStore: profileStore,
            pluginStore: pluginStore,
            enabledPlugins: enabledPlugins
        )

        let blocks = BlockComposer.contribution(
            change: blockChange,
            blockStore: BlockStore(managedDir: configDir.managedDir)
        )

        let includes = profileIncludes + blocks.includes
        let layers = profileLayers + blocks.layers

        let content = ActiveConf.render(profile: name.value, includes: includes)
        var writes = blocks.writes
        writes[configDir.relativePath(of: configDir.activeConf)] = content

        return ComposedApply(
            plan: ApplyPlan(writes: writes, deletes: blocks.deletes),
            validationContent: IncludeBuilder.compose(layers),
            conflicts: ConflictDetector.detect(layers)
        )
    }
}
