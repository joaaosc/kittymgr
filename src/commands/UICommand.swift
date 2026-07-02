import Foundation

/// `ui` (alias `pick`): launch the interactive picker wired to real stdin/stdout.
public struct UICommand {
    public let configDir: ConfigDir

    public init(configDir: ConfigDir) {
        self.configDir = configDir
    }

    public func run() throws {
        let engine = TUIEngine(
            profileStore: ProfileStore(root: configDir.profilesDir),
            pluginStore: PluginStore(root: configDir.pluginsDir),
            activePointer: ActivePointer(url: configDir.activePointerFile),
            activeConf: configDir.activeConf
        )
        try engine.start()
    }
}
