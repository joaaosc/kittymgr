import Foundation
import Testing
@testable import KittymgrCore

/// Returns a fixed local directory as if it had been fetched, so remote-install
/// logic is testable without git or the network.
private struct StubFetcher: SourceFetching {
    let root: URL
    func fetch(_ source: Source) throws -> FetchedSource { FetchedSource(root: root) }
}

private final class StubReloader: Reloading, @unchecked Sendable {
    func reload() -> ReloadOutcome { .reloaded }
}

struct CatalogTests {
    private let fm = FileManager.default

    private func makeCatalog(_ names: [String]) throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-catalog-\(UUID().uuidString)")
        let themes = root.appendingPathComponent("themes")
        try fm.createDirectory(at: themes, withIntermediateDirectories: true)
        for name in names {
            try "background #000000\n".write(to: themes.appendingPathComponent("\(name).conf"), atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test func exactAndLooseMatching() throws {
        let root = try makeCatalog(["Gruvbox", "Solarized_Light"])
        #expect(Catalog.findTheme(named: "gruvbox", in: root)?.lastPathComponent == "Gruvbox.conf")
        // Loose: unique substring match.
        #expect(Catalog.findTheme(named: "solarized", in: root)?.lastPathComponent == "Solarized_Light.conf")
        #expect(Catalog.findTheme(named: "nope", in: root) == nil)
    }

    @Test func ambiguousLooseMatchIsRejected() throws {
        let root = try makeCatalog(["Gruvbox_Dark", "Gruvbox_Light"])
        #expect(Catalog.findTheme(named: "gruvbox", in: root) == nil)  // two candidates
        #expect(Catalog.listThemes(in: root) == ["Gruvbox_Dark", "Gruvbox_Light"])
    }
}

struct RemoteInstallerTests {
    private let fm = FileManager.default

    private func makeConfigDir(activeProfile: Bool = true) throws -> ConfigDir {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-remote-\(UUID().uuidString)")
        let dir = ConfigDir(url: root)
        let profileDir = try ProfileStore(root: dir.profilesDir).create(try ProfileName(validating: "work"))
        try "font_size 12\n".write(to: profileDir.appendingPathComponent("00.conf"), atomically: true, encoding: .utf8)
        if activeProfile {
            try ActivePointer(url: dir.activePointerFile).set(try ProfileName(validating: "work"))
        }
        return dir
    }

    private func installer(_ dir: ConfigDir, fetching root: URL, dryRun: Bool = false) -> RemoteInstaller {
        RemoteInstaller(
            configDir: dir,
            dryRun: dryRun,
            fetcher: StubFetcher(root: root),
            catalogSource: Source(name: "test-catalog", kind: .git(url: "x", ref: nil)),
            validator: StubValidator(.valid),
            reloader: StubReloader()
        )
    }

    @Test func installThemeFromCatalogComposesIntoActiveConf() throws {
        let dir = try makeConfigDir()
        let catalog = fm.temporaryDirectory.appendingPathComponent("cat-\(UUID().uuidString)/themes")
        try fm.createDirectory(at: catalog, withIntermediateDirectories: true)
        try "background #282828\n".write(to: catalog.appendingPathComponent("Gruvbox.conf"), atomically: true, encoding: .utf8)

        try installer(dir, fetching: catalog.deletingLastPathComponent()).installTheme(name: "gruvbox", source: nil, log: { _ in })

        #expect(fm.fileExists(atPath: dir.managedDir.appendingPathComponent("themes/gruvbox.conf").path))
        #expect((try? String(contentsOf: dir.managedDir.appendingPathComponent("themes/gruvbox.conf"), encoding: .utf8)) == "background #282828\n")
    }

    @Test func installThemeNotFoundThrows() throws {
        let dir = try makeConfigDir()
        let empty = fm.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)")
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(throws: SourceError.self) {
            try installer(dir, fetching: empty).installTheme(name: "ghost", source: nil, log: { _ in })
        }
    }

    @Test func installPluginBundleStagesUnderPlugins() throws {
        let dir = try makeConfigDir()
        let bundle = fm.temporaryDirectory.appendingPathComponent("bundle-\(UUID().uuidString)")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try "tab_bar_style powerline\n".write(to: bundle.appendingPathComponent("a.conf"), atomically: true, encoding: .utf8)

        try installer(dir, fetching: bundle).installPlugin(name: "fancy", source: Source(name: "s", kind: .local(path: bundle.path)), log: { _ in })

        #expect(fm.fileExists(atPath: dir.pluginsDir.appendingPathComponent("fancy/a.conf").path))
        // Audit snapshot recorded.
        #expect(SnapshotStore(configDir: dir).list().contains { $0.label == "plugin-install-fancy" })
    }

    @Test func installKittenFromSourceIsAuditedAndNotExecuted() throws {
        let dir = try makeConfigDir()
        let src = fm.temporaryDirectory.appendingPathComponent("kit-\(UUID().uuidString)")
        try fm.createDirectory(at: src, withIntermediateDirectories: true)
        try "print('hi')\n".write(to: src.appendingPathComponent("hello.py"), atomically: true, encoding: .utf8)

        try installer(dir, fetching: src).installKitten(name: "hello", source: Source(name: "s", kind: .local(path: src.path)), log: { _ in })

        #expect(KittenStore(root: dir.kittensDir).exists(try PluginName(validating: "hello")))
        #expect(SnapshotStore(configDir: dir).list().contains { $0.label == "kitten-install-hello" })
    }

    @Test func dryRunInstallThemeWritesNothing() throws {
        let dir = try makeConfigDir()
        let catalog = fm.temporaryDirectory.appendingPathComponent("cat-\(UUID().uuidString)/themes")
        try fm.createDirectory(at: catalog, withIntermediateDirectories: true)
        try "background #282828\n".write(to: catalog.appendingPathComponent("Gruvbox.conf"), atomically: true, encoding: .utf8)

        var out: [String] = []
        try installer(dir, fetching: catalog.deletingLastPathComponent(), dryRun: true)
            .installTheme(name: "gruvbox", source: nil) { out.append($0) }

        #expect(out.joined(separator: "\n").contains("[dry-run]"))
        #expect(fm.fileExists(atPath: dir.managedDir.appendingPathComponent("themes/gruvbox.conf").path) == false)
    }
}
