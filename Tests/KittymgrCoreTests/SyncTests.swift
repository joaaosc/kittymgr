import Foundation
import Testing
@testable import KittymgrCore

private final class StubReloader: Reloading, @unchecked Sendable {
    func reload() -> ReloadOutcome { .reloaded }
}

private final class MovingFetcher: SourceFetching, @unchecked Sendable {
    let root: URL
    var ref: String
    private(set) var invalidations = 0
    init(root: URL, ref: String = "commit-1") { self.root = root; self.ref = ref }
    func fetch(_ source: Source) throws -> FetchedSource { FetchedSource(root: root, resolvedRef: ref) }
    func invalidate(_ source: Source) { invalidations += 1; ref = "commit-2" }
}

struct LockfileTests {
    private let fm = FileManager.default

    @Test func roundTripsAndUpserts() throws {
        var lock = Lockfile(sources: [LockedSource(name: "a", git: "g", resolvedRef: "r1", lockedAt: "t")])
        lock.upsert(LockedSource(name: "a", git: "g", resolvedRef: "r2", lockedAt: "t2"))  // replace
        lock.upsert(LockedSource(name: "b", url: "u", checksum: "c", lockedAt: "t"))
        #expect(lock.entry(for: "a")?.resolvedRef == "r2")
        #expect(lock.sources.map(\.name) == ["a", "b"])  // sorted, deduped

        let url = fm.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString).json")
        try lock.write(to: url)
        #expect(Lockfile.load(url) == lock)
    }
}

struct SynchronizerTests {
    private let fm = FileManager.default

    private struct Fixture {
        let configDir: ConfigDir
    }

    /// Config dir with profiles work+focus, an installed plugin and theme.
    private func makeFixture(manifest: String, sources: Bool = false) throws -> ConfigDir {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-sync-\(UUID().uuidString)")
        let dir = ConfigDir(url: root)
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
        _ = try ProfileStore(root: dir.profilesDir).create(try ProfileName(validating: "work"))
        try SamplePlugins.seed(into: dir.pluginsDir)  // installs "theme-sample"
        let themes = dir.managedDir.appendingPathComponent("themes")
        try fm.createDirectory(at: themes, withIntermediateDirectories: true)
        try "background #282828\n".write(to: themes.appendingPathComponent("gruvbox.conf"), atomically: true, encoding: .utf8)
        try manifest.write(to: dir.manifestFile, atomically: true, encoding: .utf8)
        return dir
    }

    private func synchronizer(_ dir: ConfigDir, dryRun: Bool = false, fetcher: (any SourceFetching)? = nil) -> Synchronizer {
        Synchronizer(configDir: dir, dryRun: dryRun, fetcher: fetcher, validator: StubValidator(.valid), reloader: StubReloader())
    }

    private let manifest = """
    [settings]
    active_profile = "work"
    active_theme = "gruvbox"

    [profiles.work]
    plugins = ["theme-sample"]

    [profiles.focus]
    plugins = []
    """

    @Test func syncReconcilesStateAndComposes() throws {
        let dir = try makeFixture(manifest: manifest)
        try synchronizer(dir).run(log: { _ in })

        // Profile focus was created from the manifest.
        #expect(ProfileStore(root: dir.profilesDir).exists(try ProfileName(validating: "focus")))
        // work has the enabled plugin from the manifest.
        #expect(ProfileStore(root: dir.profilesDir).metadata(for: try ProfileName(validating: "work")).enabledPlugins == ["theme-sample"])
        // active theme + profile applied and composed.
        #expect(ActivePointer(url: dir.activePointerFile).get() == "work")
        let active = try String(contentsOf: dir.activeConf, encoding: .utf8)
        #expect(active.contains("include plugins/theme-sample/theme.conf"))
        #expect(active.contains("include themes/gruvbox.conf"))
    }

    @Test func syncIsIdempotent() throws {
        let dir = try makeFixture(manifest: manifest)
        try synchronizer(dir).run(log: { _ in })
        let firstActive = try String(contentsOf: dir.activeConf, encoding: .utf8)

        var out: [String] = []
        try synchronizer(dir, dryRun: true).run { out.append($0) }
        #expect(out.joined(separator: "\n").contains("Already in sync"))
        #expect(try String(contentsOf: dir.activeConf, encoding: .utf8) == firstActive)
    }

    @Test func dryRunSyncWritesNothing() throws {
        let dir = try makeFixture(manifest: manifest)
        var out: [String] = []
        try synchronizer(dir, dryRun: true).run { out.append($0) }

        #expect(out.joined(separator: "\n").contains("[dry-run]"))
        #expect(fm.fileExists(atPath: dir.activeConf.path) == false)  // never activated
        #expect(ActivePointer(url: dir.activePointerFile).get() == nil)
        // No phantom profile left behind by the previewed reconcile.
        #expect(try ProfileStore(root: dir.profilesDir).list() == ["work"])
    }

    @Test func dryRunPreservesPreexistingBinaryFilesByteForByte() throws {
        let dir = try makeFixture(manifest: manifest)
        // A binary file under managed/ that no manifest entry references. A text-only
        // capture would skip it and the preview's restore would delete it.
        let binary = Data([0x00, 0x01, 0x02, 0xff, 0xfe, 0x80, 0x00, 0x7f])
        let binURL = dir.managedDir.appendingPathComponent("kittens/tool/bin")
        try fm.createDirectory(at: binURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try binary.write(to: binURL)

        try synchronizer(dir, dryRun: true).run { _ in }

        #expect(fm.fileExists(atPath: binURL.path))
        #expect(try Data(contentsOf: binURL) == binary)
    }

    @Test func invalidSyncRollsBack() throws {
        let dir = try makeFixture(manifest: manifest)
        let before = SnapshotStore(configDir: dir).currentContents()

        #expect(throws: SafetyError.self) {
            try Synchronizer(configDir: dir, validator: StubValidator(.invalid(diagnostics: "bad")), reloader: StubReloader())
                .run(log: { _ in })
        }
        // Managed surface restored: focus was not created, nothing activated.
        #expect(SnapshotStore(configDir: dir).currentContents() == before)
        #expect(ActivePointer(url: dir.activePointerFile).get() == nil)
    }

    @Test func syncMissingManifestThrows() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-nomani-\(UUID().uuidString)")
        let dir = ConfigDir(url: root)
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
        #expect(throws: ManifestError.missing) {
            try Synchronizer(configDir: dir, validator: StubValidator(.valid), reloader: StubReloader()).run(log: { _ in })
        }
    }

    @Test func updateAdvancesLockPin() throws {
        let manifestWithSource = manifest + "\n\n[[sources]]\nname = \"themes\"\ngit = \"https://example/themes\"\n"
        let dir = try makeFixture(manifest: manifestWithSource)
        let fetcher = MovingFetcher(root: dir.managedDir)  // root unused for lock

        // First sync pins commit-1.
        try synchronizer(dir, fetcher: fetcher).run(log: { _ in })
        #expect(Lockfile.load(dir.lockFile).entry(for: "themes")?.resolvedRef == "commit-1")

        // update invalidates and re-pins to the moved commit.
        try UpdateCommand(configDir: dir, dryRun: false, fetcher: fetcher, validator: StubValidator(.valid), reloader: StubReloader())
            .run(log: { _ in })
        #expect(fetcher.invalidations >= 1)
        #expect(Lockfile.load(dir.lockFile).entry(for: "themes")?.resolvedRef == "commit-2")
    }
}

private final class CheckFetcher: SourceFetching, @unchecked Sendable {
    var latest: [String: String]
    private(set) var fetches = 0
    private(set) var invalidations = 0
    init(latest: [String: String]) { self.latest = latest }
    func fetch(_ source: Source) throws -> FetchedSource { fetches += 1; return FetchedSource(root: URL(fileURLWithPath: NSTemporaryDirectory())) }
    func invalidate(_ source: Source) { invalidations += 1 }
    func resolveLatest(_ source: Source) throws -> String? { latest[source.name] }
}

struct UpdateCheckTests {
    private let fm = FileManager.default

    private func makeConfig(locked: String?) throws -> ConfigDir {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-check-\(UUID().uuidString)")
        let dir = ConfigDir(url: root)
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
        let manifest = """
        [settings]
        active_profile = "work"

        [profiles.work]
        plugins = []

        [[sources]]
        name = "themes"
        git = "https://example/themes"
        """
        try manifest.write(to: dir.manifestFile, atomically: true, encoding: .utf8)
        if let locked {
            var lock = Lockfile()
            lock.upsert(LockedSource(name: "themes", git: "https://example/themes", resolvedRef: locked, lockedAt: "t"))
            try lock.write(to: dir.lockFile)
        }
        return dir
    }

    private func report(_ dir: ConfigDir, fetcher: CheckFetcher) throws -> String {
        var out: [String] = []
        try UpdateCommand(configDir: dir, check: true, fetcher: fetcher, validator: StubValidator(.valid), reloader: StubReloader())
            .run { out.append($0) }
        return out.joined(separator: "\n")
    }

    @Test func reportsUpToDateWithoutTouchingCacheOrLock() throws {
        let dir = try makeConfig(locked: "commit-1")
        let fetcher = CheckFetcher(latest: ["themes": "commit-1"])
        let out = try report(dir, fetcher: fetcher)

        #expect(out.contains("up-to-date"))
        #expect(fetcher.fetches == 0)        // never clones
        #expect(fetcher.invalidations == 0)  // never mutates the cache
        #expect(Lockfile.load(dir.lockFile).entry(for: "themes")?.resolvedRef == "commit-1")
    }

    @Test func reportsUpdateAvailableAndLeavesLockUnchanged() throws {
        let dir = try makeConfig(locked: "commit-1")
        let out = try report(dir, fetcher: CheckFetcher(latest: ["themes": "commit-2"]))

        #expect(out.contains("update available"))
        #expect(out.contains("commit-1"))
        #expect(out.contains("commit-2"))
        // The whole point of --check: the pin does not move.
        #expect(Lockfile.load(dir.lockFile).entry(for: "themes")?.resolvedRef == "commit-1")
    }

    @Test func reportsNotPinnedWhenLockMissing() throws {
        let dir = try makeConfig(locked: nil)
        let out = try report(dir, fetcher: CheckFetcher(latest: ["themes": "commit-9"]))

        #expect(out.contains("not pinned"))
        #expect(fm.fileExists(atPath: dir.lockFile.path) == false)  // check never creates the lock
    }
}

private final class ArtifactFetcher: SourceFetching, @unchecked Sendable {
    let roots: [String: URL]
    init(_ roots: [String: URL]) { self.roots = roots }
    func fetch(_ source: Source) throws -> FetchedSource {
        guard let root = roots[source.name] else {
            throw SourceError.fetchFailed(source: source.name, detail: "no stub root for \(source.name)")
        }
        return FetchedSource(root: root)
    }
}

private final class CacheWritingArtifactFetcher: SourceFetching, @unchecked Sendable {
    let roots: [String: URL]
    let cacheDir: URL

    init(_ roots: [String: URL], cacheDir: URL) {
        self.roots = roots
        self.cacheDir = cacheDir
    }

    func fetch(_ source: Source) throws -> FetchedSource {
        let marker = cacheDir.appendingPathComponent(source.name).appendingPathComponent("marker")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "cached\n".write(to: marker, atomically: true, encoding: .utf8)
        guard let root = roots[source.name] else {
            throw SourceError.fetchFailed(source: source.name, detail: "no stub root for \(source.name)")
        }
        return FetchedSource(root: root)
    }
}

struct ArtifactSyncTests {
    private let fm = FileManager.default

    private func tempDir() -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("kittymgr-art-\(UUID().uuidString)")
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A config dir with a v2 manifest declaring a theme + plugin from two stub
    /// sources, returned with the fetcher that serves those sources.
    private func makeScenario() throws -> (ConfigDir, ArtifactFetcher) {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-artsync-\(UUID().uuidString)")
        let dir = ConfigDir(url: root)
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)

        let themeRoot = tempDir()
        try "background #101010\n".write(to: themeRoot.appendingPathComponent("mytheme.conf"), atomically: true, encoding: .utf8)
        let pluginRoot = tempDir()
        try "tab_bar_edge top\n".write(to: pluginRoot.appendingPathComponent("myplugin.conf"), atomically: true, encoding: .utf8)

        let manifest = """
        [settings]
        schema_version = 2
        active_profile = "work"
        active_theme = "mytheme"

        [profiles.work]
        plugins = ["myplugin"]

        [[sources]]
        name = "themesrc"
        git = "https://example/themes"

        [[sources]]
        name = "pluginsrc"
        git = "https://example/plugins"

        [[themes]]
        name = "mytheme"
        from = "themesrc"

        [[plugins]]
        name = "myplugin"
        from = "pluginsrc"
        """
        try manifest.write(to: dir.manifestFile, atomically: true, encoding: .utf8)
        return (dir, ArtifactFetcher(["themesrc": themeRoot, "pluginsrc": pluginRoot]))
    }

    private func sync(_ dir: ConfigDir, fetcher: any SourceFetching, dryRun: Bool = false, validation: ValidationResult = .valid) -> Synchronizer {
        Synchronizer(configDir: dir, dryRun: dryRun, fetcher: fetcher, validator: StubValidator(validation), reloader: StubReloader())
    }

    @Test func syncInstallsDeclaredArtifactsIntoCleanManaged() throws {
        let (dir, fetcher) = try makeScenario()
        try sync(dir, fetcher: fetcher).run { _ in }

        #expect(BlockStore(managedDir: dir.managedDir).themeExists("mytheme"))
        #expect(fm.fileExists(atPath: dir.pluginsDir.appendingPathComponent("myplugin").path))
        let active = try String(contentsOf: dir.activeConf, encoding: .utf8)
        #expect(active.contains("include plugins/myplugin/myplugin.conf"))
        #expect(active.contains("include themes/mytheme.conf"))
    }

    @Test func artifactInstallIsIdempotent() throws {
        let (dir, fetcher) = try makeScenario()
        try sync(dir, fetcher: fetcher).run { _ in }
        try sync(dir, fetcher: fetcher).run { _ in }  // must not throw "already installed"

        #expect(BlockStore(managedDir: dir.managedDir).themeExists("mytheme"))
        #expect(fm.fileExists(atPath: dir.pluginsDir.appendingPathComponent("myplugin").path))
    }

    @Test func dryRunStagesNoArtifactsPermanently() throws {
        let (dir, fetcher) = try makeScenario()
        var out: [String] = []
        try sync(dir, fetcher: fetcher, dryRun: true).run { out.append($0) }

        #expect(out.joined(separator: "\n").contains("[dry-run]"))
        #expect(BlockStore(managedDir: dir.managedDir).themeExists("mytheme") == false)
        #expect(fm.fileExists(atPath: dir.pluginsDir.appendingPathComponent("myplugin").path) == false)
    }

    @Test func dryRunRestoresFetcherCacheWrites() throws {
        let (dir, artifactFetcher) = try makeScenario()
        let fetcher = CacheWritingArtifactFetcher(artifactFetcher.roots, cacheDir: dir.cacheDir)

        try sync(dir, fetcher: fetcher, dryRun: true).run { _ in }

        #expect(fm.fileExists(atPath: dir.cacheDir.appendingPathComponent("themesrc/marker").path) == false)
        #expect(fm.fileExists(atPath: dir.cacheDir.appendingPathComponent("pluginsrc/marker").path) == false)
    }

    @Test func invalidSyncRollsBackStagedArtifacts() throws {
        let (dir, fetcher) = try makeScenario()
        #expect(throws: SafetyError.self) {
            try sync(dir, fetcher: fetcher, validation: .invalid(diagnostics: "bad")).run { _ in }
        }
        #expect(BlockStore(managedDir: dir.managedDir).themeExists("mytheme") == false)
        #expect(fm.fileExists(atPath: dir.pluginsDir.appendingPathComponent("myplugin").path) == false)
    }
}
