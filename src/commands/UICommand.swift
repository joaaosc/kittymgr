import Foundation

/// `ui` (alias `pick`): launch the interactive picker wired to real stdin/stdout.
///
/// On a first run (no managed layout yet) it explains, in cooked mode and before
/// touching anything, exactly what will be created and where — Enter sets up,
/// `q` quits without writing a byte.
public struct UICommand {
    public let configDir: ConfigDir

    public init(configDir: ConfigDir) {
        self.configDir = configDir
    }

    public func run() throws {
        if configDir.detectedLayout() == .absent, Terminal().isInteractive {
            guard try offerFirstRunSetup() else { return }
        }
        let engine = TUIEngine(
            profileStore: ProfileStore(root: configDir.profilesDir),
            pluginStore: PluginStore(root: configDir.pluginsDir),
            activePointer: ActivePointer(url: configDir.activePointerFile),
            activeConf: configDir.activeConf
        )
        try engine.start()
    }

    /// Returns true when the user accepted and the layout was initialized.
    private func offerFirstRunSetup() throws -> Bool {
        print("""
        \(ConsoleStyle.bold("Welcome to kittymgr."))

        Nothing is set up yet. kittymgr keeps everything it manages in one folder
        and adds a single guarded include block at the top of kitty.conf. Your own
        settings always win, and `kittymgr uninstall` puts everything back.

          Config directory   \(configDir.url.path)
          Managed folder     \(configDir.managedDir.path)
          Changed file       \(configDir.kittyConf.path)

        """)
        FileHandle.standardOutput.write(Data(ConsoleStyle.bold("Press Enter to set up now, or q to quit without touching anything. ").utf8))
        let answer = readLine(strippingNewline: true)?.lowercased() ?? "q"
        guard answer != "q", answer != "quit" else {
            print("Nothing was changed.")
            return false
        }
        try InitCommand(configDir: configDir, dryRun: false).run()
        print("")
        return true
    }
}
