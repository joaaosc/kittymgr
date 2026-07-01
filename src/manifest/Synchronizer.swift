import Foundation

/// Reconciles the on-disk state to the declarative `kittymgr.toml`, applied
/// transactionally through the existing apply engine — the `:Lazy sync` of
/// kittymgr.
///
/// It creates missing profiles, sets each profile's enabled plugins to the
/// manifest, applies the active theme, recomposes and activates the target
/// profile, and validates the result — rolling the whole managed surface back to a
/// pre-sync snapshot if validation fails. `--dry-run` previews the full
/// reconciliation as a unified diff and writes nothing. Sources named in the
/// manifest are pinned in `kittymgr.lock`.
public struct Synchronizer {
    public let configDir: ConfigDir
    public let fetcher: any SourceFetching
    public let dryRun: Bool
    public let validator: any ConfigValidating
    public let reloader: any Reloading

    public init(
        configDir: ConfigDir,
        dryRun: Bool = false,
        fetcher: (any SourceFetching)? = nil,
        validator: any ConfigValidating = KittyConfigValidator(),
        reloader: any Reloading = KittenReloader()
    ) {
        self.configDir = configDir
        self.fetcher = fetcher ?? DefaultSourceFetcher(cacheDir: configDir.cacheDir)
        self.dryRun = dryRun
        self.validator = validator
        self.reloader = reloader
    }

    public func run(log: (String) -> Void = { print($0) }) throws {
        guard let manifest = try Manifest.load(configDir.manifestFile) else {
            throw ManifestError.missing
        }
        let store = SnapshotStore(configDir: configDir)

        if dryRun {
            let before = store.currentContents()
            let existingDirs = managedDirectories()
            _ = try applyToDisk(manifest, log: { _ in })
            let diff = UnifiedDiff.diffStates(old: before, new: store.currentContents())
            try store.restore(toContents: before)
            // `restore` rewrites files but leaves directories the reconcile created;
            // drop any that are now empty so a preview leaves no phantom profile.
            pruneNewEmptyDirectories(keeping: existingDirs)
            log(diff.isEmpty ? "[dry-run] Already in sync." : "[dry-run] sync would apply:\n" + diff)
            return
        }

        let snapshot = try store.create(label: "pre-sync")
        let validationContent: String
        do {
            validationContent = try applyToDisk(manifest, log: log)
        } catch {
            try? store.restore(snapshot)
            throw error
        }

        switch validator.validate(content: validationContent) {
        case let .invalid(diagnostics):
            try store.restore(snapshot)
            log("Sync rejected by validation; rolled back to snapshot \(snapshot.id).")
            throw SafetyError.invalidConfiguration(diagnostics)
        case let .skipped(reason):
            log("Validation skipped (\(reason)).")
        case .valid:
            break
        }

        report(reloader.reload(), log: log)
        try lockSources(manifest, log: log)
        log("Synced from \(configDir.manifestFile.lastPathComponent).")
    }

    // MARK: - Reconcile

    /// Apply the manifest to disk and return the composed configuration to validate.
    private func applyToDisk(_ manifest: Manifest, log: (String) -> Void) throws -> String {
        let profileStore = ProfileStore(root: configDir.profilesDir)
        let pluginStore = PluginStore(root: configDir.pluginsDir)
        let blockStore = BlockStore(managedDir: configDir.managedDir)
        let installed = Set((try? pluginStore.list())?.map(\.name) ?? [])

        for spec in manifest.profiles {
            let name = try profileStore.resolveName(ProfileName(validating: spec.name))
            if !profileStore.exists(name) {
                _ = try profileStore.create(name)
                log("Created profile '\(name.value)'.")
            }
            for missing in spec.plugins where !installed.contains(missing) {
                log("warning: profile '\(spec.name)' wants plugin '\(missing)', which is not installed; skipping.")
            }
            var metadata = profileStore.metadata(for: name)
            metadata.enabledPlugins = spec.plugins.filter { installed.contains($0) }
            try profileStore.setMetadata(metadata, for: name)
        }

        if let theme = manifest.activeTheme {
            if blockStore.themeExists(theme) {
                try (theme + "\n").write(to: blockStore.activeThemeFile, atomically: true, encoding: .utf8)
            } else {
                log("warning: active_theme '\(theme)' is not installed; leaving theme unchanged.")
            }
        } else {
            try? FileManager.default.removeItem(at: blockStore.activeThemeFile)
        }

        guard let active = manifest.activeProfile else { return "" }
        let activeName = try profileStore.resolveName(ProfileName(validating: active))
        guard profileStore.exists(activeName) else { throw ProfileError.notFound(active) }

        let composed = try ProfileComposer.compose(
            profile: activeName,
            configDir: configDir,
            profileStore: profileStore,
            pluginStore: pluginStore
        )
        let relative = configDir.relativePath(of: configDir.activeConf)
        try ConfigStore.writeAtomically(composed.plan.writes[relative] ?? "", to: configDir.activeConf)
        try ActivePointer(url: configDir.activePointerFile).set(activeName)
        return composed.validationContent
    }

    /// Pin any not-yet-locked source referenced by the manifest.
    private func lockSources(_ manifest: Manifest, log: (String) -> Void) throws {
        guard !manifest.sources.isEmpty else { return }
        var lock = Lockfile.load(configDir.lockFile)
        for spec in manifest.sources where lock.entry(for: spec.name) == nil {
            guard let source = spec.source else { continue }
            do {
                let fetched = try fetcher.fetch(source)
                lock.upsert(LockedSource(
                    name: spec.name,
                    git: spec.git,
                    url: spec.url,
                    resolvedRef: fetched.resolvedRef,
                    checksum: fetched.checksum,
                    lockedAt: Lockfile.timestamp()
                ))
            } catch {
                log("warning: could not lock source '\(spec.name)': \(error)")
            }
        }
        try lock.write(to: configDir.lockFile)
    }

    /// Every directory under `managed/`, standardized, as a set of paths.
    private func managedDirectories() -> Set<String> {
        directories(under: configDir.managedDir).reduce(into: Set<String>()) { $0.insert($1.standardizedFileURL.path) }
    }

    /// Remove directories created during a previewed reconcile that are now empty.
    private func pruneNewEmptyDirectories(keeping existing: Set<String>) {
        let fm = FileManager.default
        // Deepest first, so a nested empty tree collapses fully.
        for url in directories(under: configDir.managedDir).sorted(by: { $0.path.count > $1.path.count }) {
            guard !existing.contains(url.standardizedFileURL.path) else { continue }
            if let contents = try? fm.contentsOfDirectory(atPath: url.path), contents.isEmpty {
                try? fm.removeItem(at: url)
            }
        }
    }

    private func directories(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            result.append(url)
        }
        return result
    }

    private func report(_ outcome: ReloadOutcome, log: (String) -> Void) {
        switch outcome {
        case .reloaded:
            log("Reloaded kitty configuration.")
        case let .unavailable(reason):
            log("Synced. Live reload unavailable: \(reason)")
        }
    }
}
