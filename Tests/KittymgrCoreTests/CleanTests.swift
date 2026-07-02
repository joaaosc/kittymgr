import Foundation
import Testing
@testable import KittymgrCore

struct CleanCommandTests {
    private let fm = FileManager.default

    private func makeConfig() throws -> ConfigDir {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-clean-\(UUID().uuidString)")
        let dir = ConfigDir(url: root)
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
        return dir
    }

    private func writeTheme(_ dir: ConfigDir, _ name: String) throws {
        let themes = dir.managedDir.appendingPathComponent("themes")
        try fm.createDirectory(at: themes, withIntermediateDirectories: true)
        try "background #000000\n".write(to: themes.appendingPathComponent("\(name).conf"), atomically: true, encoding: .utf8)
    }

    @Test func removesOrphanBackupObjectsButKeepsReferenced() throws {
        let dir = try makeConfig()
        try "font_size 12\n".write(to: dir.managedDir.appendingPathComponent("active.conf"), atomically: true, encoding: .utf8)
        try SnapshotStore(configDir: dir).create(label: "seed")
        let stray = dir.backupsDir.appendingPathComponent("objects").appendingPathComponent("deadbeef")
        try "junk".write(to: stray, atomically: true, encoding: .utf8)

        try CleanCommand(configDir: dir).run { _ in }

        #expect(fm.fileExists(atPath: stray.path) == false)              // orphan removed
        #expect(SnapshotStore(configDir: dir).missingObjects().isEmpty)  // referenced object kept
    }

    @Test func removesOrphanSourceCacheButKeepsManifestSource() throws {
        let dir = try makeConfig()
        try """
        [settings]
        schema_version = 2

        [[sources]]
        name = "themes"
        git = "https://example/themes"
        """.write(to: dir.manifestFile, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: dir.cacheDir, withIntermediateDirectories: true)
        let keep = DefaultSourceFetcher.cacheDirectoryName(for: Source(name: "themes", kind: .git(url: "https://example/themes", ref: nil)))
        try fm.createDirectory(at: dir.cacheDir.appendingPathComponent(keep), withIntermediateDirectories: true)
        let orphan = dir.cacheDir.appendingPathComponent("0000orphancache0")
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)

        try CleanCommand(configDir: dir).run { _ in }

        #expect(fm.fileExists(atPath: orphan.path) == false)
        #expect(fm.fileExists(atPath: dir.cacheDir.appendingPathComponent(keep).path))  // manifest source kept
    }

    @Test func keepsManuallyInstalledThemeByDefault() throws {
        let dir = try makeConfig()
        try writeTheme(dir, "gruvbox")  // installed, not in manifest, not active
        try "[settings]\nschema_version = 2\n".write(to: dir.manifestFile, atomically: true, encoding: .utf8)

        try CleanCommand(configDir: dir).run { _ in }  // default: no --artifacts

        #expect(BlockStore(managedDir: dir.managedDir).themeExists("gruvbox"))  // must survive
    }

    @Test func artifactsForceRemovesUnreferencedButKeepsActiveAndDeclared() throws {
        let dir = try makeConfig()
        try writeTheme(dir, "gruvbox")   // active -> keep
        try writeTheme(dir, "nord")      // declared in manifest -> keep
        try writeTheme(dir, "dracula")   // unreferenced -> remove
        try "gruvbox\n".write(to: BlockStore(managedDir: dir.managedDir).activeThemeFile, atomically: true, encoding: .utf8)
        try """
        [settings]
        schema_version = 2

        [[themes]]
        name = "nord"
        from = "src"
        """.write(to: dir.manifestFile, atomically: true, encoding: .utf8)

        try CleanCommand(configDir: dir, artifacts: true, force: true).run { _ in }

        let block = BlockStore(managedDir: dir.managedDir)
        #expect(block.themeExists("gruvbox"))          // active kept
        #expect(block.themeExists("nord"))             // declared kept
        #expect(block.themeExists("dracula") == false) // unreferenced removed
    }

    @Test func keepsPluginEnabledByProfileMetadataUnderArtifactsForce() throws {
        let dir = try makeConfig()
        try SamplePlugins.seed(into: dir.pluginsDir)  // installs "theme-sample"
        let profileStore = ProfileStore(root: dir.profilesDir)
        _ = try profileStore.create(try ProfileName(validating: "work"))
        try profileStore.setMetadata(ProfileMetadata(enabledPlugins: ["theme-sample"]), for: try ProfileName(validating: "work"))
        try "[settings]\nschema_version = 2\n".write(to: dir.manifestFile, atomically: true, encoding: .utf8)

        try CleanCommand(configDir: dir, artifacts: true, force: true).run { _ in }

        // Referenced by a profile's metadata (not the manifest) -> must be kept.
        #expect(fm.fileExists(atPath: dir.pluginsDir.appendingPathComponent("theme-sample").path))
    }

    @Test func dryRunRemovesNothing() throws {
        let dir = try makeConfig()
        try writeTheme(dir, "dracula")
        try fm.createDirectory(at: dir.cacheDir, withIntermediateDirectories: true)
        let cache = dir.cacheDir.appendingPathComponent("abc123def456")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try "[settings]\nschema_version = 2\n".write(to: dir.manifestFile, atomically: true, encoding: .utf8)

        var out: [String] = []
        try CleanCommand(configDir: dir, artifacts: true, force: true, dryRun: true).run { out.append($0) }

        #expect(out.joined(separator: "\n").contains("[dry-run]"))
        #expect(fm.fileExists(atPath: cache.path))                                  // nothing removed
        #expect(BlockStore(managedDir: dir.managedDir).themeExists("dracula"))
    }
}
