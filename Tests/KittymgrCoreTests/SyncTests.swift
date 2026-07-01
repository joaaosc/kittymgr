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
        try fm.createDirectory(at: root.appendingPathComponent("managed"), withIntermediateDirectories: true)
        #expect(throws: ManifestError.missing) {
            try Synchronizer(configDir: ConfigDir(url: root), validator: StubValidator(.valid), reloader: StubReloader()).run(log: { _ in })
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
