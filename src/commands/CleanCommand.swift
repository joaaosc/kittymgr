import Foundation

/// `clean [--artifacts] [--force]`: remove data no longer referenced by the
/// configuration. Conservative by design.
///
/// - By default only *derived* data is removed: orphaned source caches under
///   `managed/.cache/sources` and backup objects referenced by no snapshot. Both
///   are regenerable, so this is always safe.
/// - Installed themes/plugins/kittens are **never** removed unless `--artifacts` is
///   passed *and* confirmed with `--force`; that path is snapshot-protected first.
///   A manually installed artifact (absent from the manifest) therefore survives a
///   plain `clean`.
/// - Nothing outside `managed/` is ever touched. `--dry-run` previews and writes
///   nothing.
public struct CleanCommand {
    public let configDir: ConfigDir
    public let artifacts: Bool
    public let force: Bool
    public let dryRun: Bool

    public init(configDir: ConfigDir, artifacts: Bool = false, force: Bool = false, dryRun: Bool = false) {
        self.configDir = configDir
        self.artifacts = artifacts
        self.force = force
        self.dryRun = dryRun
    }

    public func run(log: (String) -> Void = { print($0) }) throws {
        let fm = FileManager.default
        let manifest = try? Manifest.load(configDir.manifestFile)
        let store = SnapshotStore(configDir: configDir)

        let orphanCaches = orphanCacheDirs(manifest: manifest)
        let orphanObjects = store.unreferencedObjects()

        var themes: [String] = [], plugins: [String] = [], kittens: [String] = []
        if artifacts {
            (themes, plugins, kittens) = unreferencedArtifacts(manifest: manifest)
        }

        let hasDerived = !orphanCaches.isEmpty || !orphanObjects.isEmpty
        let hasArtifacts = !themes.isEmpty || !plugins.isEmpty || !kittens.isEmpty
        guard hasDerived || hasArtifacts else { log("Nothing to clean."); return }

        for url in orphanCaches { log("orphan source cache: \(configDir.relativePath(of: url))") }
        if !orphanObjects.isEmpty { log("orphan backup objects: \(orphanObjects.count)") }
        for name in themes { log("unreferenced theme: \(name)") }
        for name in plugins { log("unreferenced plugin: \(name)") }
        for name in kittens { log("unreferenced kitten: \(name)") }

        if dryRun {
            log("[dry-run] clean would remove the above; nothing written.")
            return
        }

        // Derived data is regenerable — always safe to remove.
        for url in orphanCaches { try? fm.removeItem(at: url) }
        store.removeObjects(orphanObjects)

        // Artifacts are user content: require an explicit --force and snapshot first.
        if hasArtifacts {
            guard force else {
                log("Kept \(themes.count + plugins.count + kittens.count) unreferenced artifact(s). Re-run with --artifacts --force to remove them (or --dry-run to preview).")
                return
            }
            try store.create(label: "pre-clean")
            let blockStore = BlockStore(managedDir: configDir.managedDir)
            for name in themes { try? fm.removeItem(at: blockStore.themesDir.appendingPathComponent("\(name).conf")) }
            for name in plugins { try? fm.removeItem(at: configDir.pluginsDir.appendingPathComponent(name)) }
            for name in kittens { try? fm.removeItem(at: configDir.kittensDir.appendingPathComponent(name)) }
        }

        log("Cleaned.")
    }

    // MARK: - Candidates

    /// Cache directories that do not belong to any current manifest source.
    private func orphanCacheDirs(manifest: Manifest?) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: configDir.cacheDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let keep = Set((manifest?.sources ?? []).compactMap(\.source).map(DefaultSourceFetcher.cacheDirectoryName(for:)))
        return entries.filter { !keep.contains($0.lastPathComponent) }
    }

    /// Installed artifacts referenced by neither the manifest nor the live config
    /// (active theme, any profile's enabled plugins). Only these are removal
    /// candidates under `--artifacts`.
    private func unreferencedArtifacts(manifest: Manifest?) -> (themes: [String], plugins: [String], kittens: [String]) {
        let blockStore = BlockStore(managedDir: configDir.managedDir)
        let profileStore = ProfileStore(root: configDir.profilesDir)
        let pluginStore = PluginStore(root: configDir.pluginsDir)
        let kittenStore = KittenStore(root: configDir.kittensDir)

        var keepThemes = Set((manifest?.themes ?? []).map(\.name))
        if let active = blockStore.state().activeTheme { keepThemes.insert(active) }

        var keepPlugins = Set((manifest?.plugins ?? []).map(\.name))
        for name in (try? profileStore.list()) ?? [] {
            if let validated = try? ProfileName(validating: name) {
                keepPlugins.formUnion(profileStore.metadata(for: validated).enabledPlugins)
            }
        }

        let keepKittens = Set((manifest?.kittens ?? []).map(\.name))

        let themes = blockStore.availableThemes().filter { !keepThemes.contains($0) }
        let plugins = ((try? pluginStore.list()) ?? []).map(\.name).filter { !keepPlugins.contains($0) }
        let kittens = kittenStore.list().map(\.name).filter { !keepKittens.contains($0) }
        return (themes, plugins, kittens)
    }
}
