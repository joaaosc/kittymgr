import Foundation

/// Regenerates `active.conf` from a profile and its enabled plugins, records the
/// active selection, and triggers a live reload.
///
/// The include is always regenerated from scratch so disabling a plugin leaves no
/// residual lines. Writes are atomic and the active pointer is updated only after
/// a successful write. Reload failure is non-fatal.
public struct Activator {
    public let profileStore: ProfileStore
    public let pluginStore: PluginStore
    public let activePointer: ActivePointer
    public let activeConf: URL
    public let reloader: any Reloading

    public init(
        profileStore: ProfileStore,
        pluginStore: PluginStore,
        activePointer: ActivePointer,
        activeConf: URL,
        reloader: any Reloading = KittenReloader()
    ) {
        self.profileStore = profileStore
        self.pluginStore = pluginStore
        self.activePointer = activePointer
        self.activeConf = activeConf
        self.reloader = reloader
    }

    /// Generate `active.conf` for `name` without reloading or moving the pointer.
    /// Composes through `ProfileComposer`, so the active modular blocks (theme,
    /// keys, snippets) are preserved across plugin changes.
    public func regenerate(_ name: ProfileName) throws {
        let configDir = ConfigDir(url: activeConf.deletingLastPathComponent().deletingLastPathComponent())
        let composed = try ProfileComposer.compose(
            profile: name,
            configDir: configDir,
            profileStore: profileStore,
            pluginStore: pluginStore
        )
        let content = composed.plan.writes[configDir.relativePath(of: configDir.activeConf)] ?? ""
        try FileManager.default.createDirectory(
            at: activeConf.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ConfigStore.writeAtomically(content, to: activeConf)
    }

    /// Make `name` the active profile: regenerate, record it, then reload.
    public func activate(_ name: ProfileName, log: (String) -> Void) throws {
        try regenerate(name)
        try activePointer.set(name)
        reportReload(profile: name.value, log: log)
    }

    /// If `name` is the active profile, regenerate its include and reload so a
    /// metadata change (e.g. enabling a plugin) takes effect immediately.
    public func reactivateIfActive(_ name: ProfileName, log: (String) -> Void) throws {
        guard activePointer.get() == name.value else { return }
        try regenerate(name)
        reportReload(profile: name.value, log: log)
    }

    private func reportReload(profile: String, log: (String) -> Void) {
        switch reloader.reload() {
        case .reloaded:
            log("Active profile '\(profile)' reloaded in kitty.")
        case let .unavailable(reason):
            log("Active profile '\(profile)' updated. Live reload unavailable: \(reason)")
            log("Reload manually with `kitten @ load-config`, restart kitty, or send SIGUSR1 to the kitty process.")
        }
    }
}
