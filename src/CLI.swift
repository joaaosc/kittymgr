import Foundation

/// Minimal command dispatcher for the `kittymgr` executable.
public enum KittymgrCLI {
    /// Runs the CLI with arguments that exclude the executable path.
    /// Returns a process exit code.
    public static func run(_ arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            printUsage()
            return 2
        }
        let options = Array(arguments.dropFirst())
        let positionals = options.filter { !$0.hasPrefix("-") }
        let flags = options.filter { $0.hasPrefix("-") }

        do {
            switch command {
            case "init":
                _ = try InitCommand(configDir: ConfigDir.resolve()).run()
                return 0
            case "uninstall":
                let removeManaged = options.contains("--purge") || options.contains("--remove-managed")
                _ = try UninstallCommand(configDir: ConfigDir.resolve(), removeManaged: removeManaged).run()
                return 0
            case "list":
                try ListCommand(store: profileStore()).run()
                return 0
            case "create":
                guard let name = positionals.first else {
                    printError("usage: kittymgr create <name>")
                    return 2
                }
                try CreateCommand(store: profileStore(), rawName: name).run()
                return 0
            case "delete":
                guard let name = positionals.first else {
                    printError("usage: kittymgr delete <name> [--force]")
                    return 2
                }
                let force = flags.contains("--force") || flags.contains("-f")
                try DeleteCommand(store: profileStore(), rawName: name, force: force, confirm: confirmOnStdin).run()
                return 0
            case "switch":
                guard let name = positionals.first else {
                    printError("usage: kittymgr switch <name> [--force]")
                    return 2
                }
                let dir = ConfigDir.resolve()
                try SwitchCommand(
                    profileStore: ProfileStore(root: dir.profilesDir),
                    pluginStore: PluginStore(root: dir.pluginsDir),
                    activePointer: ActivePointer(url: dir.activePointerFile),
                    activeConf: dir.activeConf,
                    rawName: name,
                    force: flags.contains("--force") || flags.contains("-f")
                ).run()
                return 0
            case "check":
                guard let name = positionals.first else {
                    printError("usage: kittymgr check <name>")
                    return 2
                }
                let dir = ConfigDir.resolve()
                let passed = try CheckCommand(
                    profileStore: ProfileStore(root: dir.profilesDir),
                    pluginStore: PluginStore(root: dir.pluginsDir),
                    rawName: name
                ).run()
                return passed ? 0 : 1
            case "current":
                let dir = ConfigDir.resolve()
                try CurrentCommand(activePointer: ActivePointer(url: dir.activePointerFile)).run()
                return 0
            case "plugin":
                return runPlugin(options)
            case "ui", "pick":
                try UICommand(configDir: ConfigDir.resolve()).run()
                return 0
            case "help", "-h", "--help":
                printUsage()
                return 0
            default:
                printError("unknown command: \(command)")
                printUsage()
                return 2
            }
        } catch {
            printError("\(error)")
            return 1
        }
    }

    private static func profileStore() -> ProfileStore {
        ProfileStore(root: ConfigDir.resolve().profilesDir)
    }

    private static func runPlugin(_ options: [String]) -> Int32 {
        let dir = ConfigDir.resolve()
        let (profileOverride, rest) = extractOption("--profile", from: options)
        let positionals = rest.filter { !$0.hasPrefix("-") }

        let action: PluginCommand.Action
        switch positionals.first {
        case "list", nil:
            action = .list
        case "enable":
            guard positionals.count >= 2 else {
                printError("usage: kittymgr plugin enable <name> [--profile <name>]")
                return 2
            }
            action = .enable(positionals[1])
        case "disable":
            guard positionals.count >= 2 else {
                printError("usage: kittymgr plugin disable <name> [--profile <name>]")
                return 2
            }
            action = .disable(positionals[1])
        case let other?:
            printError("unknown plugin action: \(other)")
            return 2
        }

        do {
            try PluginCommand(
                action: action,
                profileStore: ProfileStore(root: dir.profilesDir),
                pluginStore: PluginStore(root: dir.pluginsDir),
                activePointer: ActivePointer(url: dir.activePointerFile),
                activeConf: dir.activeConf,
                profileOverride: profileOverride
            ).run()
            return 0
        } catch {
            printError("\(error)")
            return 1
        }
    }

    /// Pulls a `--name value` pair out of `args`, returning the value (if present)
    /// and the remaining arguments.
    private static func extractOption(_ name: String, from args: [String]) -> (value: String?, rest: [String]) {
        guard let index = args.firstIndex(of: name) else { return (nil, args) }
        let valueIndex = index + 1
        guard valueIndex < args.count else {
            var rest = args
            rest.remove(at: index)
            return (nil, rest)
        }
        let value = args[valueIndex]
        var rest = args
        rest.removeSubrange(index...valueIndex)
        return (value, rest)
    }

    private static func confirmOnStdin(_ prompt: String) -> Bool {
        FileHandle.standardOutput.write(Data(prompt.utf8))
        guard let line = readLine(strippingNewline: true)?.lowercased() else { return false }
        return line == "y" || line == "yes"
    }

    private static func printUsage() {
        print("""
        kittymgr — non-invasive kitty configuration manager

        Usage:
          kittymgr init                 Create the managed layer and inject the guarded include block.
          kittymgr uninstall [--purge]  Remove the guarded block; --purge also deletes the managed directory.
          kittymgr list                 List stored profiles.
          kittymgr create <name>        Create an empty profile.
          kittymgr delete <name> [-f]   Delete a profile (--force/-f skips confirmation).
          kittymgr switch <name> [-f]   Activate a profile (validates; -f overrides conflicts).
          kittymgr current              Print the active profile.
          kittymgr check <name>         Report conflicts and validation without switching.
          kittymgr plugin list          List plugins and their enabled state.
          kittymgr plugin enable <name> [--profile <name>]
          kittymgr plugin disable <name> [--profile <name>]
          kittymgr ui                   Launch the interactive picker (alias: pick).
          kittymgr help                 Show this message.

        The kitty config directory is resolved from KITTY_CONFIG_DIRECTORY,
        then $XDG_CONFIG_HOME/kitty, then ~/.config/kitty.
        """)
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }
}
