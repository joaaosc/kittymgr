import Foundation

/// Minimal interactive picker for profiles, plugins, themes, backups, and kittens.
///
/// Implemented as a cooked-mode menu loop (no raw mode, no external dependency)
/// so it is portable across macOS/Linux terminals and can never leave the shell
/// in a broken state. Every action routes through the same core commands the CLI
/// uses (`SwitchCommand`, `PluginCommand`, `BlockCommand`, `BackupCommand`), so
/// behavior stays identical and the CLI remains the source of truth. Destructive
/// actions (restore) are previewed as a unified diff before they apply.
///
/// IO is injected (`read`/`write`) so the controller is fully testable without a
/// real terminal.
public struct Picker {
    public let profileStore: ProfileStore
    public let pluginStore: PluginStore
    public let activePointer: ActivePointer
    public let activeConf: URL
    public let validator: any ConfigValidating
    public let reloader: any Reloading

    public init(
        profileStore: ProfileStore,
        pluginStore: PluginStore,
        activePointer: ActivePointer,
        activeConf: URL,
        validator: any ConfigValidating = KittyConfigValidator(),
        reloader: any Reloading = KittenReloader()
    ) {
        self.profileStore = profileStore
        self.pluginStore = pluginStore
        self.activePointer = activePointer
        self.activeConf = activeConf
        self.validator = validator
        self.reloader = reloader
    }

    /// `active.conf` is canonically `<configDir>/managed/active.conf`; recover the
    /// config root for the subsystems that key off it (blocks, backups, kittens).
    private var configDir: ConfigDir {
        ConfigDir(url: activeConf.deletingLastPathComponent().deletingLastPathComponent())
    }

    public func run(read: () -> String?, write: (String) -> Void) throws {
        while true {
            try render(write)
            write("Commands: <n> switch | f <n> force | t <plugin> toggle | theme <name> | "
                + "snap [label] | diff <id> | restore <id> preview | restore! <id> apply | r refresh | q quit")
            guard let line = read()?.trimmingCharacters(in: .whitespaces), !isQuit(line) else {
                write("Bye.")
                return
            }
            try handle(line, write: write)
        }
    }

    // MARK: - Rendering

    private func render(_ write: (String) -> Void) throws {
        let active = activePointer.get()
        let profiles = try profileStore.list()

        write("")
        write("Profiles:")
        if profiles.isEmpty {
            write("  (none — create one with `kittymgr create <name>`)")
        }
        for (index, name) in profiles.enumerated() {
            let marker = name == active ? " *" : ""
            write("  \(index + 1)) \(name)\(marker)")
        }

        let plugins = try pluginStore.list()
        if let active, let name = try? ProfileName(validating: active) {
            let enabled = Set(profileStore.metadata(for: name).enabledPlugins)
            write("Plugins (active profile '\(active)'):")
            if plugins.isEmpty { write("  (none)") }
            for plugin in plugins {
                write("  \(enabled.contains(plugin.name) ? "[x]" : "[ ]") \(plugin.name)")
            }
        } else {
            write("Plugins: (switch to a profile to toggle)")
        }

        renderThemes(write)
        renderBackups(write)
        renderKittens(write)
    }

    private func renderThemes(_ write: (String) -> Void) {
        let store = BlockStore(managedDir: configDir.managedDir)
        let themes = store.availableThemes()
        guard !themes.isEmpty else { return }
        let active = store.state().activeTheme
        write("Themes:")
        for theme in themes {
            write("  \(theme == active ? "*" : " ") \(theme)")
        }
    }

    private func renderBackups(_ write: (String) -> Void) {
        let snapshots = SnapshotStore(configDir: configDir).list()
        guard let latest = snapshots.first else { return }
        write("Backups: \(snapshots.count) snapshot(s). Latest: \(latest.id) (\(latest.label ?? "-"))")
    }

    private func renderKittens(_ write: (String) -> Void) {
        let kittens = KittenStore(root: configDir.kittensDir).list()
        guard !kittens.isEmpty else { return }
        write("Kittens: " + kittens.map(\.name).joined(separator: ", "))
    }

    // MARK: - Command handling

    private func handle(_ line: String, write: (String) -> Void) throws {
        if line == "r" || line.isEmpty { return }

        if line.hasPrefix("t ") {
            togglePlugin(argument(line, after: "t "), write: write)
        } else if line.hasPrefix("theme ") {
            switchTheme(argument(line, after: "theme "), write: write)
        } else if line.hasPrefix("snap") {
            createSnapshot(label: argument(line, after: "snap"), write: write)
        } else if line.hasPrefix("diff ") {
            restore(id: argument(line, after: "diff "), apply: false, write: write)
        } else if line.hasPrefix("restore! ") {
            restore(id: argument(line, after: "restore! "), apply: true, write: write)
        } else if line.hasPrefix("restore ") {
            restore(id: argument(line, after: "restore "), apply: false, write: write)
        } else if line.hasPrefix("f ") {
            switchToIndex(Int(argument(line, after: "f ")), force: true, write: write)
        } else if let index = Int(line) {
            switchToIndex(index, force: false, write: write)
        } else {
            write("Unknown command: \(line)")
        }
    }

    private func switchToIndex(_ index: Int?, force: Bool, write: (String) -> Void) {
        guard let index, let names = try? profileStore.list(), index >= 1, index <= names.count else {
            write("No such profile.")
            return
        }
        let target = names[index - 1]
        do {
            try SwitchCommand(
                profileStore: profileStore,
                pluginStore: pluginStore,
                activePointer: activePointer,
                activeConf: activeConf,
                rawName: target,
                force: force,
                validator: validator,
                reloader: reloader
            ).run(log: write)
        } catch let error as SafetyError {
            write("Blocked: \(error)")
            if case .unresolvedConflicts = error {
                write("Use 'f \(index)' to force the switch.")
            }
        } catch {
            write("error: \(error)")
        }
    }

    private func togglePlugin(_ pluginName: String, write: (String) -> Void) {
        guard let active = activePointer.get(), let name = try? ProfileName(validating: active) else {
            write("No active profile; switch to one first.")
            return
        }
        let enabled = Set(profileStore.metadata(for: name).enabledPlugins)
        let action: PluginCommand.Action = enabled.contains(pluginName)
            ? .disable(pluginName)
            : .enable(pluginName)
        do {
            try PluginCommand(
                action: action,
                profileStore: profileStore,
                pluginStore: pluginStore,
                activePointer: activePointer,
                activeConf: activeConf,
                reloader: reloader
            ).run(log: write)
        } catch {
            write("error: \(error)")
        }
    }

    private func switchTheme(_ name: String, write: (String) -> Void) {
        guard !name.isEmpty else { write("usage: theme <name>"); return }
        runBlock(.themeSwitch(name: name), write: write)
    }

    private func createSnapshot(label: String, write: (String) -> Void) {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        do {
            try BackupCommand(action: .create(label: trimmed.isEmpty ? nil : trimmed), configDir: configDir).run(log: write)
        } catch {
            write("error: \(error)")
        }
    }

    /// Preview (`apply == false`) prints the unified diff via `--dry-run`; apply
    /// performs the restore. Destructive restores are thus always previewable first.
    private func restore(id: String, apply: Bool, write: (String) -> Void) {
        guard !id.isEmpty else { write("usage: restore <id>"); return }
        do {
            try BackupCommand(action: .restore(id: id), configDir: configDir, dryRun: !apply).run(log: write)
            if !apply { write("Type 'restore! \(id)' to apply this restore.") }
        } catch {
            write("error: \(error)")
        }
    }

    private func runBlock(_ action: BlockCommand.Action, write: (String) -> Void) {
        do {
            try BlockCommand(action: action, configDir: configDir, validator: validator, reloader: reloader).run(log: write)
        } catch {
            write("error: \(error)")
        }
    }

    private func argument(_ line: String, after prefix: String) -> String {
        String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private func isQuit(_ line: String) -> Bool {
        line == "q" || line == "quit"
    }
}
