import Foundation
import Testing
@testable import KittymgrCore

struct InitUninstallTests {
    private let fm = FileManager.default

    private func makeConfigDir() throws -> ConfigDir {
        let base = fm.temporaryDirectory
            .appendingPathComponent("kittymgr-test-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return ConfigDir(url: base.appendingPathComponent("kitty"))
    }

    private func silent(_ message: String) {}

    private func write(_ content: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func initInjectsExactlyOneBlockAndCreatesManagedLayer() throws {
        let dir = try makeConfigDir()
        try write("font_size 12\n", to: dir.kittyConf)

        let changed = try InitCommand(configDir: dir).run(log: silent)
        #expect(changed)

        let conf = try read(dir.kittyConf)
        let markers = conf.components(separatedBy: "\n").filter { $0 == Guard.beginMarker }.count
        #expect(markers == 1)
        #expect(conf.contains(Guard.includeLine))
        #expect(fm.fileExists(atPath: dir.managedDir.path))
        #expect(fm.fileExists(atPath: dir.activeConf.path))
    }

    @Test func initIsIdempotent() throws {
        let dir = try makeConfigDir()
        try write("font_size 12\n", to: dir.kittyConf)

        _ = try InitCommand(configDir: dir).run(log: silent)
        let afterFirst = try read(dir.kittyConf)
        let secondChanged = try InitCommand(configDir: dir).run(log: silent)
        let afterSecond = try read(dir.kittyConf)

        #expect(secondChanged == false)
        #expect(afterFirst == afterSecond)
    }

    @Test func initCreatesTimestampedBackup() throws {
        let dir = try makeConfigDir()
        try write("font_size 12\n", to: dir.kittyConf)

        _ = try InitCommand(configDir: dir).run(log: silent)

        let backups = try fm.contentsOfDirectory(atPath: dir.url.path)
            .filter { $0.hasPrefix("kitty.conf.bak.") }
        #expect(backups.count == 1)
    }

    @Test func linesOutsideGuardAreUnchanged() throws {
        let dir = try makeConfigDir()
        let original = "font_size 12\nbackground #101010\nmap ctrl+c copy_to_clipboard\n"
        try write(original, to: dir.kittyConf)

        _ = try InitCommand(configDir: dir).run(log: silent)

        let conf = try read(dir.kittyConf)
        #expect(conf.hasPrefix(original))
    }

    @Test func uninstallRestoresOriginalByteForByte() throws {
        let dir = try makeConfigDir()
        let original = "font_size 12\nbackground #101010\n"
        try write(original, to: dir.kittyConf)

        _ = try InitCommand(configDir: dir).run(log: silent)
        _ = try UninstallCommand(configDir: dir).run(log: silent)

        let restored = try read(dir.kittyConf)
        #expect(restored == original)
    }

    @Test func initCreatesConfWhenMissingAndUninstallRemovesIt() throws {
        let dir = try makeConfigDir()
        #expect(fm.fileExists(atPath: dir.kittyConf.path) == false)

        _ = try InitCommand(configDir: dir).run(log: silent)
        #expect(fm.fileExists(atPath: dir.kittyConf.path))
        #expect(Guard.contains(in: try read(dir.kittyConf)))

        _ = try UninstallCommand(configDir: dir).run(log: silent)
        #expect(fm.fileExists(atPath: dir.kittyConf.path) == false)
    }

    @Test func uninstallPurgeRemovesManagedDirectory() throws {
        let dir = try makeConfigDir()
        try write("font_size 12\n", to: dir.kittyConf)

        _ = try InitCommand(configDir: dir).run(log: silent)
        _ = try UninstallCommand(configDir: dir, removeManaged: true).run(log: silent)

        #expect(fm.fileExists(atPath: dir.managedDir.path) == false)
    }
}
