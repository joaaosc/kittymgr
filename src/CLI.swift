import Foundation

/// Minimal command dispatcher for the `kittymgr` executable.
public enum KittymgrCLI {
    /// Runs the CLI with arguments that exclude the executable path.
    /// Returns a process exit code.
    public static func run(_ arguments: [String]) -> Int32 {
        // `--dry-run` is a cross-cutting global flag: strip it before dispatch so
        // every command sees a clean argument list and inherits preview behavior.
        var args = arguments
        let dryRun = args.contains("--dry-run")
        args.removeAll { $0 == "--dry-run" }

        // `--help`/`-h` anywhere documents the full command surface, so both
        // `kittymgr --help` and `kittymgr <cmd> --help` are answered.
        if args.contains("--help") || args.contains("-h") {
            printUsage()
            return 0
        }

        guard let command = args.first else {
            printUsage()
            return 2
        }
        let options = Array(args.dropFirst())
        let positionals = options.filter { !$0.hasPrefix("-") }
        let flags = options.filter { $0.hasPrefix("-") }

        // `backup` consumes `--dry-run` natively (it prints a diff). For other
        // mutating commands the full apply-pipeline preview arrives in a later
        // milestone; until then `--dry-run` must still guarantee no writes happen.
        let mutatingWithoutPreview: Set<String> = [
            "init", "uninstall", "create", "delete", "plugin", "ui", "pick",
        ]
        if dryRun && mutatingWithoutPreview.contains(command) {
            print("[dry-run] \(command): no changes made. Use `kittymgr backup ... --dry-run` to preview diffs.")
            return 0
        }

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
                    force: flags.contains("--force") || flags.contains("-f"),
                    dryRun: dryRun
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
            case "profile":
                return runProfile(options, dryRun: dryRun)
            case "theme":
                return runTheme(options, dryRun: dryRun)
            case "key":
                return runKey(options, dryRun: dryRun)
            case "snippet":
                return runSnippet(options, dryRun: dryRun)
            case "kitten":
                return runKitten(options, dryRun: dryRun)
            case "backup":
                return runBackup(options, dryRun: dryRun)
            case "apply":
                try ApplyCommand(configDir: ConfigDir.resolve(), dryRun: dryRun).run()
                return 0
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

    /// `profile` namespace: the same profile operations as the top-level commands,
    /// grouped under one verb (`profile list/create/switch/delete/current`).
    private static func runProfile(_ options: [String], dryRun: Bool) -> Int32 {
        let positionals = options.filter { !$0.hasPrefix("-") }
        let flags = options.filter { $0.hasPrefix("-") }
        let dir = ConfigDir.resolve()
        let force = flags.contains("--force") || flags.contains("-f")

        do {
            switch positionals.first {
            case "list", nil:
                try ListCommand(store: ProfileStore(root: dir.profilesDir)).run()
            case "create":
                guard positionals.count >= 2 else {
                    printError("usage: kittymgr profile create <name>")
                    return 2
                }
                if dryRun { print("[dry-run] profile create: no changes made."); return 0 }
                try CreateCommand(store: ProfileStore(root: dir.profilesDir), rawName: positionals[1]).run()
            case "switch":
                guard positionals.count >= 2 else {
                    printError("usage: kittymgr profile switch <name> [--force] [--dry-run]")
                    return 2
                }
                try SwitchCommand(
                    profileStore: ProfileStore(root: dir.profilesDir),
                    pluginStore: PluginStore(root: dir.pluginsDir),
                    activePointer: ActivePointer(url: dir.activePointerFile),
                    activeConf: dir.activeConf,
                    rawName: positionals[1],
                    force: force,
                    dryRun: dryRun
                ).run()
            case "delete":
                guard positionals.count >= 2 else {
                    printError("usage: kittymgr profile delete <name> [--force]")
                    return 2
                }
                if dryRun { print("[dry-run] profile delete: no changes made."); return 0 }
                try DeleteCommand(
                    store: ProfileStore(root: dir.profilesDir),
                    rawName: positionals[1],
                    force: force,
                    confirm: confirmOnStdin
                ).run()
            case "current":
                try CurrentCommand(activePointer: ActivePointer(url: dir.activePointerFile)).run()
            case let other?:
                printError("unknown profile action: \(other)")
                return 2
            }
            return 0
        } catch {
            printError("\(error)")
            return 1
        }
    }

    private static func runBlock(_ action: BlockCommand.Action, dryRun: Bool) -> Int32 {
        do {
            try BlockCommand(action: action, configDir: ConfigDir.resolve(), dryRun: dryRun).run()
            return 0
        } catch {
            printError("\(error)")
            return 1
        }
    }

    /// `theme list | install <name> [--from <file>] | switch <name> | remove <name>`.
    private static func runTheme(_ options: [String], dryRun: Bool) -> Int32 {
        let (from, rest) = extractOption("--from", from: options)
        let positionals = rest.filter { !$0.hasPrefix("-") }
        switch positionals.first {
        case "list", nil:
            return runBlock(.themeList, dryRun: dryRun)
        case "install":
            guard positionals.count >= 2 else { printError("usage: kittymgr theme install <name> [--from <file>]"); return 2 }
            let content: String
            if let from {
                guard let text = try? String(contentsOfFile: from, encoding: .utf8) else {
                    printError("cannot read theme file: \(from)"); return 2
                }
                content = text
            } else {
                content = ""
            }
            return runBlock(.themeInstall(name: positionals[1], content: content), dryRun: dryRun)
        case "switch":
            guard positionals.count >= 2 else { printError("usage: kittymgr theme switch <name>"); return 2 }
            return runBlock(.themeSwitch(name: positionals[1]), dryRun: dryRun)
        case "remove":
            guard positionals.count >= 2 else { printError("usage: kittymgr theme remove <name>"); return 2 }
            return runBlock(.themeRemove(name: positionals[1]), dryRun: dryRun)
        case let other?:
            printError("unknown theme action: \(other)"); return 2
        }
    }

    /// `key list | add '<chord> <action>' | remove <chord>`.
    private static func runKey(_ options: [String], dryRun: Bool) -> Int32 {
        let positionals = options.filter { !$0.hasPrefix("-") }
        switch positionals.first {
        case "list", nil:
            return runBlock(.keyList, dryRun: dryRun)
        case "add":
            let spec = positionals.dropFirst().joined(separator: " ")
            let parts = spec.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { printError("usage: kittymgr key add '<chord> <action>'"); return 2 }
            return runBlock(.keyAdd(chord: parts[0], action: parts[1]), dryRun: dryRun)
        case "remove":
            guard positionals.count >= 2 else { printError("usage: kittymgr key remove <chord>"); return 2 }
            return runBlock(.keyRemove(chord: positionals[1]), dryRun: dryRun)
        case let other?:
            printError("unknown key action: \(other)"); return 2
        }
    }

    /// `snippet list | add <name> [--from <file>] | remove <name>`.
    private static func runSnippet(_ options: [String], dryRun: Bool) -> Int32 {
        let (from, rest) = extractOption("--from", from: options)
        let positionals = rest.filter { !$0.hasPrefix("-") }
        switch positionals.first {
        case "list", nil:
            return runBlock(.snippetList, dryRun: dryRun)
        case "add":
            guard positionals.count >= 2 else { printError("usage: kittymgr snippet add <name> [--from <file>]"); return 2 }
            let content: String
            if let from {
                guard let text = try? String(contentsOfFile: from, encoding: .utf8) else {
                    printError("cannot read snippet file: \(from)"); return 2
                }
                content = text
            } else {
                content = ""
            }
            return runBlock(.snippetAdd(name: positionals[1], content: content), dryRun: dryRun)
        case "remove":
            guard positionals.count >= 2 else { printError("usage: kittymgr snippet remove <name>"); return 2 }
            return runBlock(.snippetRemove(name: positionals[1]), dryRun: dryRun)
        case let other?:
            printError("unknown snippet action: \(other)"); return 2
        }
    }

    /// `kitten list | install <name> --from <path> | remove <name>`.
    private static func runKitten(_ options: [String], dryRun: Bool) -> Int32 {
        let (from, rest) = extractOption("--from", from: options)
        let positionals = rest.filter { !$0.hasPrefix("-") }

        let action: KittenCommand.Action
        switch positionals.first {
        case "list", nil:
            action = .list
        case "install":
            guard positionals.count >= 2 else {
                printError("usage: kittymgr kitten install <name> --from <path>")
                return 2
            }
            guard let from else {
                printError("usage: kittymgr kitten install <name> --from <path>")
                return 2
            }
            action = .install(name: positionals[1], source: from)
        case "remove":
            guard positionals.count >= 2 else {
                printError("usage: kittymgr kitten remove <name>")
                return 2
            }
            action = .remove(name: positionals[1])
        case let other?:
            printError("unknown kitten action: \(other)")
            return 2
        }

        do {
            try KittenCommand(action: action, configDir: ConfigDir.resolve(), dryRun: dryRun).run()
            return 0
        } catch {
            printError("\(error)")
            return 1
        }
    }

    private static func runBackup(_ options: [String], dryRun: Bool) -> Int32 {
        let (label, rest) = extractOption("--label", from: options)
        let positionals = rest.filter { !$0.hasPrefix("-") }

        let action: BackupCommand.Action
        switch positionals.first {
        case "create", nil:
            action = .create(label: label)
        case "list":
            action = .list
        case "restore":
            guard positionals.count >= 2 else {
                printError("usage: kittymgr backup restore <id> [--dry-run]")
                return 2
            }
            action = .restore(id: positionals[1])
        case let other?:
            printError("unknown backup action: \(other)")
            return 2
        }

        do {
            try BackupCommand(action: action, configDir: ConfigDir.resolve(), dryRun: dryRun).run()
            return 0
        } catch {
            printError("\(error)")
            return 1
        }
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
          kittymgr apply                Re-compose & re-apply the active profile (validate; rollback on failure).
          kittymgr current              Print the active profile.
          kittymgr profile <list|create|switch|delete|current> ...
                                        Same operations grouped under one verb.
          kittymgr check <name>         Report conflicts and validation without switching.
          kittymgr plugin list          List plugins and their enabled state.
          kittymgr plugin enable <name> [--profile <name>]
          kittymgr plugin disable <name> [--profile <name>]
          kittymgr theme <list|install|switch|remove> ...   Manage theme blocks (one active).
          kittymgr key <list|add|remove> ...        Manage keybinding blocks (additive).
          kittymgr snippet <list|add|remove> ...    Manage snippet blocks (additive).
          kittymgr kitten <list|install|remove> ... Manage kittens (scripts; never auto-run).
          kittymgr backup create [--label <text>]   Snapshot the managed surface.
          kittymgr backup list          List snapshots (id, timestamp, label).
          kittymgr backup restore <id>  Restore a snapshot byte-for-byte.
          kittymgr ui                   Launch the interactive picker (alias: pick).
          kittymgr help                 Show this message.

        Global flags:
          --dry-run                     Preview a change as a unified diff; write nothing.

        The kitty config directory is resolved from KITTY_CONFIG_DIRECTORY,
        then $XDG_CONFIG_HOME/kitty, then ~/.config/kitty.
        """)
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }
}
