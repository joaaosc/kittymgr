import Foundation
import Testing
@testable import KittymgrCore

struct SnapshotStoreTests {
    private let fm = FileManager.default

    private func makeConfigDir() throws -> ConfigDir {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-backup-\(UUID().uuidString)")
        try fm.createDirectory(
            at: root.appendingPathComponent("managed/profiles/work"),
            withIntermediateDirectories: true
        )
        let dir = ConfigDir(url: root)
        try "include managed/active.conf\n".write(to: dir.kittyConf, atomically: true, encoding: .utf8)
        try "font_size 12\n".write(to: dir.managedDir.appendingPathComponent("active.conf"), atomically: true, encoding: .utf8)
        try "background #000000\n".write(
            to: root.appendingPathComponent("managed/profiles/work/base.conf"),
            atomically: true,
            encoding: .utf8
        )
        return dir
    }

    @Test func createThenListShowsLabeledEntry() throws {
        let store = SnapshotStore(configDir: try makeConfigDir())
        let manifest = try store.create(label: "demo")

        let listed = store.list()
        #expect(listed.count == 1)
        #expect(listed.first?.id == manifest.id)
        #expect(listed.first?.label == "demo")
        #expect(manifest.files.map(\.path).sorted()
            == ["kitty.conf", "managed/active.conf", "managed/profiles/work/base.conf"])
    }

    @Test func restoreReturnsByteForByteState() throws {
        let dir = try makeConfigDir()
        let store = SnapshotStore(configDir: dir)
        let base = dir.url.appendingPathComponent("managed/profiles/work/base.conf")
        let original = try Data(contentsOf: base)
        let snapshot = try store.create(label: "pre")

        // Modify a tracked file and add a new one after the snapshot.
        try "background #ffffff\n".write(to: base, atomically: true, encoding: .utf8)
        let extra = dir.url.appendingPathComponent("managed/profiles/work/extra.conf")
        try "cursor_shape beam\n".write(to: extra, atomically: true, encoding: .utf8)

        try store.restore(snapshot)

        #expect(try Data(contentsOf: base) == original)
        #expect(fm.fileExists(atPath: extra.path) == false)
    }

    @Test func backupStoreIsExcludedFromTrackedSurface() throws {
        let store = SnapshotStore(configDir: try makeConfigDir())
        _ = try store.create()             // creates managed/backups/...
        let manifest = try store.create()  // must not re-capture the backup store
        #expect(manifest.files.allSatisfy { !$0.path.contains("backups") })
    }

    @Test func listIgnoresIncompleteEntries() throws {
        let dir = try makeConfigDir()
        let store = SnapshotStore(configDir: dir)
        _ = try store.create()
        // A stray non-manifest file in the snapshots dir is never treated as history.
        let stray = dir.backupsDir.appendingPathComponent("snapshots/partial.tmp")
        try "garbage".write(to: stray, atomically: true, encoding: .utf8)
        #expect(store.list().count == 1)
    }

    @Test func manifestResolvesUniqueIDPrefix() throws {
        let store = SnapshotStore(configDir: try makeConfigDir())
        let manifest = try store.create()
        let prefix = String(manifest.id.prefix(8))
        #expect(store.manifest(matching: prefix)?.id == manifest.id)
    }
}

struct BackupCommandTests {
    private let fm = FileManager.default

    private func makeConfigDir() throws -> (ConfigDir, URL) {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-backupcmd-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("managed"), withIntermediateDirectories: true)
        let dir = ConfigDir(url: root)
        let active = dir.managedDir.appendingPathComponent("active.conf")
        try "font_size 12\n".write(to: active, atomically: true, encoding: .utf8)
        return (dir, active)
    }

    @Test func dryRunRestorePrintsDiffAndWritesNothing() throws {
        let (dir, active) = try makeConfigDir()
        let snapshot = try SnapshotStore(configDir: dir).create()

        try "font_size 18\n".write(to: active, atomically: true, encoding: .utf8)
        let beforeDryRun = try Data(contentsOf: active)

        var out: [String] = []
        try BackupCommand(action: .restore(id: snapshot.id), configDir: dir, dryRun: true)
            .run { out.append($0) }

        let joined = out.joined(separator: "\n")
        #expect(joined.contains("[dry-run]"))
        #expect(joined.contains("-font_size 18"))
        #expect(joined.contains("+font_size 12"))
        #expect(try Data(contentsOf: active) == beforeDryRun)
    }

    @Test func restoreAppliesChange() throws {
        let (dir, active) = try makeConfigDir()
        let snapshot = try SnapshotStore(configDir: dir).create()
        try "font_size 18\n".write(to: active, atomically: true, encoding: .utf8)

        try BackupCommand(action: .restore(id: snapshot.id), configDir: dir, dryRun: false).run { _ in }
        #expect(try String(contentsOf: active, encoding: .utf8) == "font_size 12\n")
    }

    @Test func createListsNewSnapshot() throws {
        let (dir, _) = try makeConfigDir()
        try BackupCommand(action: .create(label: "demo"), configDir: dir, dryRun: false).run { _ in }

        var out: [String] = []
        try BackupCommand(action: .list, configDir: dir, dryRun: false).run { out.append($0) }
        #expect(out.contains { $0.contains("demo") })
    }

    @Test func restoreUnknownIDThrows() throws {
        let (dir, _) = try makeConfigDir()
        #expect(throws: BackupError.notFound("nope")) {
            try BackupCommand(action: .restore(id: "nope"), configDir: dir, dryRun: false).run { _ in }
        }
    }
}
