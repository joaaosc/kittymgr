import Foundation

/// Minimal interactive picker for profiles and plugins.
///
/// Implemented as a cooked-mode menu loop (no raw mode, no external dependency)
/// so it is portable across macOS/Linux terminals and can never leave the shell
/// in a broken state. Every action routes through the same core commands the CLI
/// uses (`SwitchCommand`, `PluginCommand`), so behavior stays identical and the
/// CLI remains the source of truth.
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

    public func run(read: () -> String?, write: (String) -> Void) throws {
        while true {
            try render(write)
            write("Commands: <number> switch | f <number> force-switch | t <plugin> toggle | r refresh | q quit")
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
    }

    // MARK: - Command handling

    private func handle(_ line: String, write: (String) -> Void) throws {
        if line == "r" || line.isEmpty {
            return
        }
        if line.hasPrefix("t ") {
            togglePlugin(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces), write: write)
            return
        }
        if line.hasPrefix("f ") {
            switchToIndex(Int(line.dropFirst(2).trimmingCharacters(in: .whitespaces)), force: true, write: write)
            return
        }
        if let index = Int(line) {
            switchToIndex(index, force: false, write: write)
            return
        }
        write("Unknown command: \(line)")
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

    private func isQuit(_ line: String) -> Bool {
        line == "q" || line == "quit"
    }
}
