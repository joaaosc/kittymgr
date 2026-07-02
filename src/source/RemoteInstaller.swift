import Foundation

/// Orchestrates fetching a `Source` and installing what it contains as a theme,
/// plugin, or kitten. The fetch layer (`SourceFetching`) is injected, so this is
/// fully testable without the network or git.
///
/// Themes route through `BlockCommand` (composed + validated via the apply
/// pipeline); kittens through `KittenStore` (snapshot-audited, never executed);
/// plugin bundles are staged atomically under `managed/plugins/<name>/`.
public struct RemoteInstaller {
    public let configDir: ConfigDir
    public let fetcher: any SourceFetching
    public let catalogSource: Source
    public let dryRun: Bool
    public let validator: any ConfigValidating
    public let reloader: any Reloading

    /// The built-in theme catalog.
    public static let kittyThemesCatalog = Source(
        name: "kitty-themes",
        kind: .git(url: "https://github.com/kovidgoyal/kitty-themes", ref: nil)
    )

    public init(
        configDir: ConfigDir,
        dryRun: Bool = false,
        fetcher: (any SourceFetching)? = nil,
        catalogSource: Source = RemoteInstaller.kittyThemesCatalog,
        validator: any ConfigValidating = KittyConfigValidator(),
        reloader: any Reloading = KittenReloader()
    ) {
        self.configDir = configDir
        self.fetcher = fetcher ?? DefaultSourceFetcher(cacheDir: configDir.cacheDir)
        self.catalogSource = catalogSource
        self.dryRun = dryRun
        self.validator = validator
        self.reloader = reloader
    }

    // MARK: Themes

    /// Install a theme. `source == nil` resolves the name from the built-in catalog.
    public func installTheme(name: String, source: Source?, log: (String) -> Void = { print($0) }) throws {
        let effective = source ?? catalogSource
        let fetched = try fetcher.fetch(effective)
        guard let themeFile = resolveThemeFile(name: name, source: effective, fetched: fetched) else {
            throw SourceError.fetchFailed(source: name, detail: "theme not found in source")
        }
        let content = try String(contentsOf: themeFile, encoding: .utf8)
        try BlockCommand(
            action: .themeInstall(name: name, content: content),
            configDir: configDir,
            dryRun: dryRun,
            validator: validator,
            reloader: reloader
        ).run(log: log)
    }

    public func searchThemes(query: String, log: (String) -> Void = { print($0) }) throws {
        let fetched = try fetcher.fetch(catalogSource)
        let all = Catalog.listThemes(in: fetched.root)
        let normalized = Catalog.normalize(query)
        let hits = query.isEmpty ? all : all.filter { Catalog.normalize($0).contains(normalized) }
        guard !hits.isEmpty else { log("No matching themes."); return }
        for theme in hits { log(theme) }
    }

    private func resolveThemeFile(name: String, source: Source, fetched: FetchedSource) -> URL? {
        // A local file or a single downloaded file *is* the theme.
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: fetched.root.path, isDirectory: &isDirectory)
        if !isDirectory.boolValue { return fetched.root }
        if case .url = source.kind {
            return (try? FileManager.default.contentsOfDirectory(at: fetched.root, includingPropertiesForKeys: nil))?
                .first { $0.pathExtension == "conf" }
        }
        return Catalog.findTheme(named: name, in: fetched.root)
    }

    // MARK: Kittens

    public func installKitten(name: String, source: Source, log: (String) -> Void = { print($0) }) throws {
        let validated = try PluginName(validating: name)
        let store = KittenStore(root: configDir.kittensDir)
        guard !store.exists(validated) else { throw KittenError.alreadyInstalled(validated.value) }

        let fetched = try fetcher.fetch(source)
        if dryRun {
            log("[dry-run] Would install kitten '\(validated.value)' from the fetched source.")
            return
        }
        try SnapshotStore(configDir: configDir).create(label: "kitten-install-\(validated.value)")
        try store.install(validated, from: fetched.root)
        log("Installed kitten '\(validated.value)'. Not executed; invoke explicitly with kitty +kitten.")
    }

    // MARK: Plugins

    /// Stage a fetched plugin bundle (its `.conf` files) atomically under
    /// `managed/plugins/<name>/`.
    public func installPlugin(name: String, source: Source, log: (String) -> Void = { print($0) }) throws {
        let validated = try PluginName(validating: name)
        let fm = FileManager.default
        let destination = configDir.pluginsDir.appendingPathComponent(validated.value)
        guard !fm.fileExists(atPath: destination.path) else {
            throw ProfileError.alreadyExists(validated.value)
        }

        let fetched = try fetcher.fetch(source)
        let confs = (try? fm.contentsOfDirectory(at: fetched.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
            .filter { $0.pathExtension == "conf" } ?? []
        guard !confs.isEmpty else {
            throw SourceError.fetchFailed(source: name, detail: "no .conf files in source")
        }

        if dryRun {
            log("[dry-run] Would install plugin '\(validated.value)' (\(confs.count) file(s)).")
            return
        }

        try SnapshotStore(configDir: configDir).create(label: "plugin-install-\(validated.value)")
        try stagePluginFiles(validated, confs: confs, into: destination)
        log("Installed plugin '\(validated.value)'. Enable it with: kittymgr plugin enable \(validated.value)")
    }

    // MARK: Staging (no snapshot, validation, or reload)

    /// The primitives `sync` uses: they only stage files onto the managed surface,
    /// leaving one snapshot / validation / reload to the caller (the reconcile).
    /// Each is idempotent — a no-op when the artifact is already present.

    /// Write a theme's `.conf` under `managed/themes/<name>.conf`.
    public func stageTheme(name: String, source: Source) throws {
        let blockStore = BlockStore(managedDir: configDir.managedDir)
        guard !blockStore.themeExists(name) else { return }
        let fetched = try fetcher.fetch(source)
        guard let themeFile = resolveThemeFile(name: name, source: source, fetched: fetched) else {
            throw SourceError.fetchFailed(source: name, detail: "theme not found in source")
        }
        let content = try String(contentsOf: themeFile, encoding: .utf8)
        try FileManager.default.createDirectory(at: blockStore.themesDir, withIntermediateDirectories: true)
        try content.write(to: blockStore.themesDir.appendingPathComponent("\(name).conf"), atomically: true, encoding: .utf8)
    }

    /// Stage a fetched plugin bundle under `managed/plugins/<name>/`.
    public func stagePlugin(name: String, source: Source) throws {
        let validated = try PluginName(validating: name)
        let fm = FileManager.default
        let destination = configDir.pluginsDir.appendingPathComponent(validated.value)
        guard !fm.fileExists(atPath: destination.path) else { return }

        let fetched = try fetcher.fetch(source)
        let confs = (try? fm.contentsOfDirectory(at: fetched.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
            .filter { $0.pathExtension == "conf" } ?? []
        guard !confs.isEmpty else {
            throw SourceError.fetchFailed(source: name, detail: "no .conf files in source")
        }
        try stagePluginFiles(validated, confs: confs, into: destination)
    }

    /// Copy a fetched kitten under `managed/kittens/<name>/` (never executed).
    public func stageKitten(name: String, source: Source) throws {
        let validated = try PluginName(validating: name)
        let store = KittenStore(root: configDir.kittensDir)
        guard !store.exists(validated) else { return }
        let fetched = try fetcher.fetch(source)
        try store.install(validated, from: fetched.root)
    }

    /// Atomically publish `confs` as `destination` via a staging directory + rename.
    private func stagePluginFiles(_ name: PluginName, confs: [URL], into destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: configDir.pluginsDir, withIntermediateDirectories: true)
        let staging = configDir.pluginsDir.appendingPathComponent(".\(name.value).tmp.\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for conf in confs {
            try fm.copyItem(at: conf, to: staging.appendingPathComponent(conf.lastPathComponent))
        }
        try fm.moveItem(at: staging, to: destination)
    }
}
