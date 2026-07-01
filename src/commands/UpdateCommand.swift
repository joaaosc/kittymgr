import Foundation

/// `update [<source>]`: re-resolve remote sources to their newest commit, re-pin the
/// lockfile, and reconcile via `sync`.
///
/// Without an argument every source is refreshed; with one, only that source. The
/// cache entry is invalidated so the fetch re-resolves, then the reconcile flows
/// through the same snapshot-protected sync.
public struct UpdateCommand {
    public let configDir: ConfigDir
    public let target: String?
    public let dryRun: Bool
    public let fetcher: any SourceFetching
    public let validator: any ConfigValidating
    public let reloader: any Reloading

    public init(
        configDir: ConfigDir,
        target: String? = nil,
        dryRun: Bool = false,
        fetcher: (any SourceFetching)? = nil,
        validator: any ConfigValidating = KittyConfigValidator(),
        reloader: any Reloading = KittenReloader()
    ) {
        self.configDir = configDir
        self.target = target
        self.dryRun = dryRun
        self.fetcher = fetcher ?? DefaultSourceFetcher(cacheDir: configDir.cacheDir)
        self.validator = validator
        self.reloader = reloader
    }

    public func run(log: (String) -> Void = { print($0) }) throws {
        guard let manifest = try Manifest.load(configDir.manifestFile) else {
            throw ManifestError.missing
        }
        let sources = manifest.sources.filter { target == nil || $0.name == target }
        if let target, sources.isEmpty {
            throw ManifestError.sourceNotFound(target)
        }

        if dryRun {
            for spec in sources { log("[dry-run] Would re-resolve source '\(spec.name)'.") }
            try synchronizer(dryRun: true).run(log: log)
            return
        }

        var lock = Lockfile.load(configDir.lockFile)
        for spec in sources {
            guard let source = spec.source else { continue }
            fetcher.invalidate(source)
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
                log("Updated '\(spec.name)' -> \(fetched.resolvedRef ?? fetched.checksum ?? "resolved").")
            } catch {
                log("warning: could not update '\(spec.name)': \(error)")
            }
        }
        try lock.write(to: configDir.lockFile)
        try synchronizer(dryRun: false).run(log: log)
    }

    private func synchronizer(dryRun: Bool) -> Synchronizer {
        Synchronizer(configDir: configDir, dryRun: dryRun, fetcher: fetcher, validator: validator, reloader: reloader)
    }
}
