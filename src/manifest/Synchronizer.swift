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
            // Capture the full byte surface (binary-safe) so the preview reverts
            // every file exactly — a text-only capture would drop, then delete,
            // preexisting binary files under kittymgr/.
            let beforeSurface = try store.currentSurface()
            let beforeManagedSurface = try managedFileSurface()
            let beforeText = beforeSurface.compactMapValues { String(data: $0, encoding: .utf8) }
            let existingDirs = managedDirectories()
            let diff: String
            do {
                _ = try applyToDisk(manifest, log: { _ in })
                diff = UnifiedDiff.diffStates(old: beforeText, new: store.currentContents())
            } catch {
                // Even a mid-apply failure must leave the surface untouched.
                try? store.restore(toSurface: beforeSurface)
                try? restoreManagedFileSurface(beforeManagedSurface)
                pruneNewEmptyDirectories(keeping: existingDirs)
                throw error
            }
            try store.restore(toSurface: beforeSurface)
            try restoreManagedFileSurface(beforeManagedSurface)
            // `restore` rewrites files but leaves directories the reconcile created;
            // drop any that are now empty so a preview leaves no phantom profile.
            pruneNewEmptyDirectories(keeping: existingDirs)
            log(diff.isEmpty ? "[dry-run] Already in sync." : "[dry-run] sync would apply:\n" + diff)
            return
        }

        let snapshot = try store.create(label: "pre-sync")
        // `restore` rewrites/removes files but leaves directories the reconcile
        // created; capture the pre-apply dir set so a rollback can prune them and
        // not leave an empty (falsely "installed") artifact directory behind.
        let existingDirs = managedDirectories()
        let validationContent: String
        do {
            validationContent = try applyToDisk(manifest, log: log)
        } catch {
            try? store.restore(snapshot)
            pruneNewEmptyDirectories(keeping: existingDirs)
            throw error
        }

        switch validator.validate(content: validationContent) {
        case let .invalid(diagnostics):
            try store.restore(snapshot)
            pruneNewEmptyDirectories(keeping: existingDirs)
            log("Sync rejected by validation; rolled back to snapshot \(snapshot.id).")
            throw SafetyError.invalidConfiguration(diagnostics)
        case let .skipped(reason):
            log("Validation skipped (\(reason)).")
        case .valid:
            break
        }

        log("Snapshot pre-sync: \(snapshot.id).")
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
        // Install declared artifacts first so the reconcile below sees them present.
        try installArtifacts(manifest, blockStore: blockStore, pluginStore: pluginStore, log: log)
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

    /// Install any declared artifact that is missing, staging it onto the managed
    /// surface. Uses `RemoteInstaller`'s stage-only primitives (no nested
    /// snapshot/reload) so the reconcile's single `pre-sync` snapshot + validation +
    /// reload covers the installs too — an invalid result rolls the whole thing back.
    /// Idempotent; specs with an empty `from` are skipped, unknown sources warn.
    private func installArtifacts(
        _ manifest: Manifest,
        blockStore: BlockStore,
        pluginStore: PluginStore,
        log: (String) -> Void
    ) throws {
        let installer = RemoteInstaller(configDir: configDir, fetcher: fetcher, validator: validator, reloader: reloader)
        let kittenStore = KittenStore(root: configDir.kittensDir)
        let fm = FileManager.default

        func source(for spec: InstallSpec, kind: String) -> Source? {
            guard !spec.from.isEmpty else { return nil }
            guard var resolved = manifest.sources.first(where: { $0.name == spec.from })?.source else {
                log("warning: \(kind) '\(spec.name)' references unknown source '\(spec.from)'; skipping.")
                return nil
            }
            if let ref = spec.ref, case let .git(url, _) = resolved.kind {
                resolved = Source(name: resolved.name, kind: .git(url: url, ref: ref))
            }
            return resolved
        }

        for spec in manifest.themes where !blockStore.themeExists(spec.name) {
            guard let src = source(for: spec, kind: "theme") else { continue }
            try installer.stageTheme(name: spec.name, source: src)
            log("Installed theme '\(spec.name)' from '\(spec.from)'.")
        }
        for spec in manifest.plugins where !fm.fileExists(atPath: configDir.pluginsDir.appendingPathComponent(spec.name).path) {
            guard let src = source(for: spec, kind: "plugin") else { continue }
            try installer.stagePlugin(name: spec.name, source: src)
            log("Installed plugin '\(spec.name)' from '\(spec.from)'.")
        }
        for spec in manifest.kittens {
            if let validated = try? PluginName(validating: spec.name), kittenStore.exists(validated) { continue }
            guard let src = source(for: spec, kind: "kitten") else { continue }
            try installer.stageKitten(name: spec.name, source: src)
            log("Installed kitten '\(spec.name)' from '\(spec.from)'.")
        }
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

    /// Every directory under `kittymgr/`, standardized, as a set of paths.
    private func managedDirectories() -> Set<String> {
        directories(under: configDir.managedDir).reduce(into: Set<String>()) { $0.insert($1.standardizedFileURL.path) }
    }

    private func managedFileSurface() throws -> [String: Data] {
        var result: [String: Data] = [:]
        for file in files(under: configDir.managedDir) {
            result[configDir.relativePath(of: file)] = try Data(contentsOf: file)
        }
        return result
    }

    private func restoreManagedFileSurface(_ surface: [String: Data]) throws {
        let fm = FileManager.default
        let wanted = Set(surface.keys)
        for file in files(under: configDir.managedDir) where !wanted.contains(configDir.relativePath(of: file)) {
            try fm.removeItem(at: file)
        }
        for (path, data) in surface {
            let destination = configDir.url.appendingPathComponent(path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        }
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

    private func files(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDirectory { result.append(url) }
        }
        return result.sorted { $0.path < $1.path }
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
