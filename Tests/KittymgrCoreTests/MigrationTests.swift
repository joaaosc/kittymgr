import Foundation
import Testing
@testable import KittymgrCore

struct LayoutMigrationTests {
    private let fm = FileManager.default

    private func makeConfigDir() throws -> ConfigDir {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-migration-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return ConfigDir(url: root)
    }

    private func write(_ content: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func legacyConf(userContent: String) -> String {
        [
            Guard.beginMarker,
            "# Managed by kittymgr. Do not edit inside these markers.",
            Guard.legacyIncludeLine,
            Guard.endMarker,
        ].joined(separator: "\n") + "\n\n" + userContent
    }

    private func regularFiles(under root: URL) throws -> [String: Data] {
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return [:]
        }
        var files: [String: Data] = [:]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let rootPath = root.standardizedFileURL.path
            let filePath = url.standardizedFileURL.path
            files[String(filePath.dropFirst(rootPath.count + 1))] = try Data(contentsOf: url)
        }
        return files
    }

    @Test func initMigratesPopulatedLegacyLayout() throws {
        let dir = try makeConfigDir()
        let original = legacyConf(userContent: "font_size 14\n")
        try write(original, to: dir.kittyConf)
        try write("font_size 12\n", to: dir.legacyManagedDir.appendingPathComponent("active.conf"))
        try write("background #000\n", to: dir.legacyManagedDir.appendingPathComponent("profiles/work/base.conf"))
        try write("foreground #fff\n", to: dir.legacyManagedDir.appendingPathComponent("plugins/theme/plugin.conf"))
        try write("old backup\n", to: dir.url.appendingPathComponent("kitty.conf.bak.legacy"))
        try Lockfile(sources: [
            LockedSource(name: "themes", git: "https://example.invalid/themes", resolvedRef: "abc", lockedAt: "2026-07-03T00:00:00Z"),
        ]).write(to: dir.legacyLockFile)

        let changed = try InitCommand(configDir: dir).run(log: { _ in })

        #expect(changed)
        #expect(fm.fileExists(atPath: dir.legacyManagedDir.path) == false)
        #expect(fm.fileExists(atPath: dir.managedDir.path))
        #expect(try read(dir.managedDir.appendingPathComponent("profiles/work/base.conf")) == "background #000\n")
        #expect(try read(dir.managedDir.appendingPathComponent("plugins/theme/plugin.conf")) == "foreground #fff\n")
        #expect(fm.fileExists(atPath: dir.legacyLockFile.path) == false)
        #expect(Lockfile.load(dir.lockFile).entry(for: "themes")?.resolvedRef == "abc")

        let migrated = try read(dir.kittyConf)
        #expect(migrated.contains(Guard.includeLine))
        #expect(migrated.contains(Guard.legacyIncludeLine) == false)
        #expect(migrated.hasSuffix("font_size 14\n"))

        let confBackups = try fm.contentsOfDirectory(at: dir.confBackupsDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("kitty.conf.bak.") }
        #expect(confBackups.count == 1)
        #expect(try read(confBackups[0]) == original)
        #expect(try read(dir.url.appendingPathComponent("kitty.conf.bak.legacy")) == "old backup\n")
        #expect(SnapshotStore(configDir: dir).list().isEmpty == false)
    }

    @Test func initDryRunDoesNotMutateLegacyLayout() throws {
        let dir = try makeConfigDir()
        try write(legacyConf(userContent: "font_size 14\n"), to: dir.kittyConf)
        try write("font_size 12\n", to: dir.legacyManagedDir.appendingPathComponent("active.conf"))
        try Lockfile(sources: [
            LockedSource(name: "themes", git: "https://example.invalid/themes", resolvedRef: "abc", lockedAt: "2026-07-03T00:00:00Z"),
        ]).write(to: dir.legacyLockFile)

        let before = try regularFiles(under: dir.url)
        var out: [String] = []
        let changed = try InitCommand(configDir: dir, dryRun: true).run { out.append($0) }
        let after = try regularFiles(under: dir.url)

        #expect(changed)
        #expect(after == before)
        #expect(fm.fileExists(atPath: dir.managedDir.path) == false)
        #expect(out.joined(separator: "\n").contains("managed/ -> kittymgr/"))
        #expect(out.joined(separator: "\n").contains(Guard.includeLine))
    }

    @Test func legacyLayoutBlocksNonInitCommands() throws {
        let dir = try makeConfigDir()
        try write("font_size 12\n", to: dir.legacyManagedDir.appendingPathComponent("active.conf"))

        #expect(throws: ConfigLayoutError.legacy(command: "list")) {
            try dir.requireCurrentLayout(for: "list")
        }
    }

    @Test func mixedLayoutFailsWithRepairInstruction() throws {
        let dir = try makeConfigDir()
        try fm.createDirectory(at: dir.legacyManagedDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)

        #expect(throws: ConfigLayoutError.self) {
            try InitCommand(configDir: dir).run(log: { _ in })
        }
        #expect(throws: ConfigLayoutError.self) {
            try dir.requireCurrentLayout(for: "list")
        }
    }
}
