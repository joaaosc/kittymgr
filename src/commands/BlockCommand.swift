import Foundation

/// `theme` / `key` / `snippet`: install, switch, and remove modular blocks.
///
/// Each block lives in its own include file under `kittymgr/themes`, `kittymgr/keys`,
/// or `kittymgr/snippets`. A change is composed with the active profile and applied
/// through `ApplyTransaction`, so it is snapshot-protected, validated, and rolled
/// back on failure (and previewable with `--dry-run`). Themes are mutually
/// exclusive (one active at a time); keybindings and snippets are additive.
public struct BlockCommand {
    public enum Action: Equatable {
        case themeList
        case themeInstall(name: String, content: String)
        case themeSwitch(name: String)
        case themeRemove(name: String)
        case keyList
        case keyAdd(chord: String, action: String)
        case keyRemove(chord: String)
        case snippetList
        case snippetAdd(name: String, content: String)
        case snippetRemove(name: String)
    }

    public let action: Action
    public let configDir: ConfigDir
    public let dryRun: Bool
    public let validator: any ConfigValidating
    public let reloader: any Reloading

    public init(
        action: Action,
        configDir: ConfigDir,
        dryRun: Bool = false,
        validator: any ConfigValidating = KittyConfigValidator(),
        reloader: any Reloading = KittenReloader()
    ) {
        self.action = action
        self.configDir = configDir
        self.dryRun = dryRun
        self.validator = validator
        self.reloader = reloader
    }

    public func run(log: (String) -> Void = { print($0) }) throws {
        switch action {
        case .themeList:
            listThemes(log: log)
        case .keyList:
            listSlugs(in: blockStore.keysDir, label: "Keybindings", log: log)
        case .snippetList:
            listSlugs(in: blockStore.snippetsDir, label: "Snippets", log: log)

        case let .themeInstall(name, content):
            try ensureValid(name)
            try apply(.installTheme(name: try slug(name), content: content), describe: "Installed theme '\(name)'.", log: log)
        case let .themeSwitch(name):
            let validated = try slug(name)
            guard blockStore.themeExists(validated) else { throw ProfileError.notFound(name) }
            try apply(.switchTheme(name: validated), describe: "Switched theme to '\(name)'.", log: log)
        case let .themeRemove(name):
            let validated = try slug(name)
            guard blockStore.themeExists(validated) else { throw ProfileError.notFound(name) }
            try apply(.removeTheme(name: validated), describe: "Removed theme '\(name)'.", log: log)

        case let .keyAdd(chord, mapAction):
            let keySlug = try slug(chordSlug(chord))
            let content = "map \(chord) \(mapAction)\n"
            try apply(.addKey(slug: keySlug, content: content), describe: "Added keybinding '\(chord)'.", log: log)
        case let .keyRemove(chord):
            let keySlug = try slug(chordSlug(chord))
            try apply(.removeKey(slug: keySlug), describe: "Removed keybinding '\(chord)'.", log: log)

        case let .snippetAdd(name, content):
            let snippetSlug = try slug(name)
            try apply(.addSnippet(slug: snippetSlug, content: content), describe: "Added snippet '\(name)'.", log: log)
        case let .snippetRemove(name):
            let snippetSlug = try slug(name)
            try apply(.removeSnippet(slug: snippetSlug), describe: "Removed snippet '\(name)'.", log: log)
        }
    }

    // MARK: Apply

    private func apply(_ change: BlockChange, describe: String, log: (String) -> Void) throws {
        let transaction = ApplyTransaction(
            snapshotStore: SnapshotStore(configDir: configDir),
            validator: validator,
            reloader: reloader
        )

        let plan: ApplyPlan
        let validationContent: String
        if let profile = activeProfile() {
            let composed = try ProfileComposer.compose(
                profile: profile,
                configDir: configDir,
                profileStore: ProfileStore(root: configDir.profilesDir),
                pluginStore: PluginStore(root: configDir.pluginsDir),
                blockChange: change
            )
            plan = composed.plan
            validationContent = composed.validationContent
        } else {
            // No active profile yet: change only the block files; they compose in
            // on the next switch.
            let blocks = BlockComposer.contribution(change: change, blockStore: blockStore)
            plan = ApplyPlan(writes: blocks.writes, deletes: blocks.deletes)
            validationContent = IncludeBuilder.compose(blocks.layers)
        }

        let result = try transaction.apply(plan: plan, validationContent: validationContent, dryRun: dryRun, log: log)
        if result.status == .applied { log(describe) }
    }

    // MARK: Listing

    private func listThemes(log: (String) -> Void) {
        let themes = blockStore.availableThemes()
        let active = blockStore.state().activeTheme
        guard !themes.isEmpty else {
            log("No themes installed under kittymgr/themes/.")
            return
        }
        for theme in themes {
            log("\(theme == active ? "*" : " ") \(theme)")
        }
    }

    private func listSlugs(in directory: URL, label: String, log: (String) -> Void) {
        let names = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
            .filter { $0.pathExtension == "conf" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted() ?? []
        guard !names.isEmpty else {
            log("No \(label.lowercased()) under \(directory.lastPathComponent)/.")
            return
        }
        log("\(label):")
        for name in names { log("  \(name)") }
    }

    // MARK: Helpers

    private var blockStore: BlockStore { BlockStore(managedDir: configDir.managedDir) }

    private func activeProfile() -> ProfileName? {
        guard let active = ActivePointer(url: configDir.activePointerFile).get(),
              let name = try? ProfileName(validating: active),
              ProfileStore(root: configDir.profilesDir).exists(name)
        else { return nil }
        return name
    }

    /// First whitespace-separated token (the key chord); the rest is the action.
    private func chordSlug(_ chord: String) -> String {
        chord.replacingOccurrences(of: "+", with: "-")
    }

    private func slug(_ raw: String) throws -> String {
        try ManagedName.validate(raw)
    }

    private func ensureValid(_ name: String) throws {
        _ = try slug(name)
    }
}
