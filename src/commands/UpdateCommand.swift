import Foundation

/// `update [<source>]`: re-resolve remote sources to their newest commit, re-pin the
/// lockfile, and reconcile via `sync`.
///
/// Without an argument every source is refreshed; with one, only that source. The
/// cache entry is invalidated so the fetch re-resolves, then the reconcile flows
/// through the same snapshot-protected sync.
///
/// `--check` is the read-only counterpart: it resolves each source's newest commit
/// on the remote (via `git ls-remote`, no clone) and reports which are behind the
/// lock, without touching the cache, the lock, or the managed config.
public struct UpdateCommand {
    public let configDir: ConfigDir
    public let target: String?
    public let dryRun: Bool
    /// `--check`: report which sources have a newer commit than the lock and exit,
    /// without re-resolving the cache, re-pinning the lock, or running `sync`.
    public let check: Bool
    public let fetcher: any SourceFetching
    public let validator: any ConfigValidating
    public let reloader: any Reloading

    public init(
        configDir: ConfigDir,
        target: String? = nil,
        dryRun: Bool = false,
        check: Bool = false,
        fetcher: (any SourceFetching)? = nil,
        validator: any ConfigValidating = KittyConfigValidator(),
        reloader: any Reloading = KittenReloader()
    ) {
        self.configDir = configDir
        self.target = target
        self.dryRun = dryRun
        self.check = check
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

        if check {
            try reportOutdated(sources, log: log)
            return
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

    /// Read-only outdated report: resolve each source's latest remote commit and
    /// compare to the lock. Never writes the lock or touches the managed config.
    private func reportOutdated(_ sources: [SourceSpec], log: (String) -> Void) throws {
        let lock = Lockfile.load(configDir.lockFile)
        for spec in sources {
            guard let source = spec.source else {
                log("\(spec.name): not a fetchable source; skipped.")
                continue
            }
            do {
                guard let latest = try fetcher.resolveLatest(source) else {
                    log("\(spec.name): outdated check not supported for this source type.")
                    continue
                }
                if let locked = lock.entry(for: spec.name)?.resolvedRef {
                    if locked == latest {
                        log("\(spec.name): up-to-date (\(Self.short(locked))).")
                    } else {
                        log("\(spec.name): update available \(Self.short(locked)) -> \(Self.short(latest)).")
                    }
                } else {
                    log("\(spec.name): not pinned; latest \(Self.short(latest)). Run `kittymgr update \(spec.name)` to pin.")
                }
            } catch {
                log("warning: could not check '\(spec.name)': \(error)")
            }
        }
    }

    private static func short(_ ref: String) -> String {
        ref.count > 10 ? String(ref.prefix(10)) : ref
    }

    private func synchronizer(dryRun: Bool) -> Synchronizer {
        Synchronizer(configDir: configDir, dryRun: dryRun, fetcher: fetcher, validator: validator, reloader: reloader)
    }
}
