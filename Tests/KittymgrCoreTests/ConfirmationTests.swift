import Foundation
import Testing
@testable import KittymgrCore

private struct ConfirmStubReloader: Reloading {
    func reload() -> ReloadOutcome { .reloaded }
}

/// Sensitive commands (`uninstall`, `backup restore`, `sync`) must state exactly
/// what they will remove or overwrite, mutate nothing when declined, and skip
/// the prompt under `--force`.
struct ConfirmationTests {
    private let fm = FileManager.default

    private func tempConfigDir() throws -> ConfigDir {
        let url = fm.temporaryDirectory.appendingPathComponent("kittymgr-confirm-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return ConfigDir(url: url)
    }

    @Test func gateRequiresForceWithoutInteractiveTerminal() {
        #expect(KittymgrCLI.confirmationAvailable(force: true, interactive: false))
        #expect(KittymgrCLI.confirmationAvailable(force: true, interactive: true))
        #expect(KittymgrCLI.confirmationAvailable(force: false, interactive: true))
        #expect(KittymgrCLI.confirmationAvailable(force: false, interactive: false) == false)
    }

    // MARK: - uninstall

    @Test func uninstallDeclinedChangesNothing() throws {
        let dir = try tempConfigDir()
        _ = try InitCommand(configDir: dir, dryRun: false).run()

        var prompts: [String] = []
        var logs: [String] = []
        let done = try UninstallCommand(configDir: dir, confirm: { prompts.append($0); return false })
            .run { logs.append($0) }

        #expect(done == false)
        #expect(prompts.count == 1)
        #expect(prompts[0].contains(dir.kittyConf.path))
        #expect(logs.contains { $0.contains("Aborted") })
        let conf = try String(contentsOf: dir.kittyConf, encoding: .utf8)
        #expect(conf.contains("include kittymgr/active.conf"))
        #expect(fm.fileExists(atPath: dir.managedDir.path))
    }

    @Test func uninstallPurgePromptNamesTheManagedDirAndCounts() throws {
        let dir = try tempConfigDir()
        _ = try InitCommand(configDir: dir, dryRun: false).run()
        try CreateCommand(store: ProfileStore(root: dir.profilesDir), rawName: "work").run { _ in }
        _ = try SnapshotStore(configDir: dir).create(label: "keepsake")

        var prompt = ""
        let done = try UninstallCommand(configDir: dir, removeManaged: true, confirm: { prompt = $0; return false })
            .run { _ in }

        #expect(done == false)
        #expect(prompt.contains(dir.managedDir.path))
        #expect(prompt.contains("1 profile"))
        #expect(prompt.contains("1 snapshot"))
        #expect(fm.fileExists(atPath: dir.managedDir.path))
    }

    @Test func uninstallForceSkipsThePrompt() throws {
        let dir = try tempConfigDir()
        _ = try InitCommand(configDir: dir, dryRun: false).run()

        var asked = false
        let done = try UninstallCommand(configDir: dir, removeManaged: true, force: true, confirm: { _ in
            asked = true
            return false
        }).run { _ in }

        #expect(done)
        #expect(asked == false)
        #expect(fm.fileExists(atPath: dir.managedDir.path) == false)
    }

    // MARK: - backup restore

    @Test func backupRestoreDeclinedChangesNothing() throws {
        let dir = try tempConfigDir()
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
        let file = dir.managedDir.appendingPathComponent("active.conf")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        let snapshot = try SnapshotStore(configDir: dir).create(label: "before")
        try "modified\n".write(to: file, atomically: true, encoding: .utf8)

        var prompt = ""
        var logs: [String] = []
        try BackupCommand(action: .restore(id: snapshot.id), configDir: dir, confirm: { prompt = $0; return false })
            .run { logs.append($0) }

        #expect(try String(contentsOf: file, encoding: .utf8) == "modified\n")
        #expect(prompt.contains(snapshot.id))
        #expect(prompt.contains("1 file"))
        #expect(logs.contains { $0.contains("Aborted") })
    }

    @Test func backupRestoreDryRunCreatesNoSafetySnapshot() throws {
        let dir = try tempConfigDir()
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
        let file = dir.managedDir.appendingPathComponent("active.conf")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        let store = SnapshotStore(configDir: dir)
        let snapshot = try store.create(label: "before")
        try "modified\n".write(to: file, atomically: true, encoding: .utf8)
        let snapshotsBefore = store.list()

        try BackupCommand(action: .restore(id: snapshot.id), configDir: dir, dryRun: true).run { _ in }

        #expect(try String(contentsOf: file, encoding: .utf8) == "modified\n")
        #expect(store.list() == snapshotsBefore)
    }

    @Test func backupRestoreConfirmedRestoresAndForceSkipsPrompt() throws {
        let dir = try tempConfigDir()
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
        let file = dir.managedDir.appendingPathComponent("active.conf")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        let snapshot = try SnapshotStore(configDir: dir).create(label: nil)

        try "modified\n".write(to: file, atomically: true, encoding: .utf8)
        try BackupCommand(action: .restore(id: snapshot.id), configDir: dir, confirm: { _ in true })
            .run { _ in }
        #expect(try String(contentsOf: file, encoding: .utf8) == "original\n")

        try "modified again\n".write(to: file, atomically: true, encoding: .utf8)
        var asked = false
        try BackupCommand(action: .restore(id: snapshot.id), configDir: dir, force: true, confirm: { _ in
            asked = true
            return false
        }).run { _ in }
        #expect(asked == false)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original\n")
    }

    // MARK: - reversibility of destructive commands (Etapa 8 findings)

    @Test func backupRestoreCreatesPreRestoreSafetySnapshot() throws {
        let dir = try tempConfigDir()
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
        let file = dir.managedDir.appendingPathComponent("active.conf")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        let store = SnapshotStore(configDir: dir)
        let snapshot = try store.create(label: "before")
        try "modified\n".write(to: file, atomically: true, encoding: .utf8)

        try BackupCommand(action: .restore(id: snapshot.id), configDir: dir, force: true).run { _ in }
        #expect(try String(contentsOf: file, encoding: .utf8) == "original\n")

        // The restore itself is undoable: the safety snapshot returns the state
        // that existed right before it.
        let safety = store.list().first { $0.label == "pre-restore" }
        #expect(safety != nil)
        if let safety {
            try store.restore(safety)
            #expect(try String(contentsOf: file, encoding: .utf8) == "modified\n")
        }
    }

    @Test func backupRestoreAbortsWhenPreRestoreSnapshotFails() throws {
        let dir = try tempConfigDir()
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
        let store = SnapshotStore(configDir: dir)
        let snapshot = try store.create(label: "empty")

        try fm.removeItem(at: dir.backupsDir.appendingPathComponent("objects"))
        try "not a directory".write(
            to: dir.backupsDir.appendingPathComponent("objects"),
            atomically: true,
            encoding: .utf8
        )
        let profileDir = dir.profilesDir.appendingPathComponent("work")
        try fm.createDirectory(at: profileDir, withIntermediateDirectories: true)
        let conf = profileDir.appendingPathComponent("base.conf")
        try "font_size 14\n".write(to: conf, atomically: true, encoding: .utf8)

        do {
            try BackupCommand(action: .restore(id: snapshot.id), configDir: dir, force: true).run { _ in }
            Issue.record("Expected pre-restore snapshot creation to fail.")
        } catch {
            #expect(fm.fileExists(atPath: conf.path))
            #expect(try String(contentsOf: conf, encoding: .utf8) == "font_size 14\n")
        }
    }

    @Test func deleteWithSnapshotStoreIsUndoable() throws {
        let dir = try tempConfigDir()
        _ = try InitCommand(configDir: dir, dryRun: false).run()
        try CreateCommand(store: ProfileStore(root: dir.profilesDir), rawName: "work").run { _ in }
        let conf = dir.profilesDir.appendingPathComponent("work/base.conf")
        try "font_size 13\n".write(to: conf, atomically: true, encoding: .utf8)

        let store = SnapshotStore(configDir: dir)
        var logs: [String] = []
        try DeleteCommand(
            store: ProfileStore(root: dir.profilesDir),
            rawName: "work",
            force: true,
            snapshots: store
        ).run { logs.append($0) }

        #expect(fm.fileExists(atPath: dir.profilesDir.appendingPathComponent("work").path) == false)
        #expect(logs.contains { $0.contains("Undo:") })

        let safety = store.list().first { $0.label == "pre-delete" }
        #expect(safety != nil)
        if let safety {
            try store.restore(safety)
            #expect(try String(contentsOf: conf, encoding: .utf8) == "font_size 13\n")
        }
    }

    @Test func deleteAbortsWhenPreDeleteSnapshotFails() throws {
        let dir = try tempConfigDir()
        let profileStore = ProfileStore(root: dir.profilesDir)
        try CreateCommand(store: profileStore, rawName: "work").run { _ in }
        let conf = dir.profilesDir.appendingPathComponent("work/base.conf")
        try "font_size 15\n".write(to: conf, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
        try "not a directory".write(to: dir.backupsDir, atomically: true, encoding: .utf8)

        do {
            try DeleteCommand(
                store: profileStore,
                rawName: "work",
                force: true,
                snapshots: SnapshotStore(configDir: dir)
            ).run { _ in }
            Issue.record("Expected pre-delete snapshot creation to fail.")
        } catch {
            #expect(profileStore.exists(try ProfileName(validating: "work")))
            #expect(try String(contentsOf: conf, encoding: .utf8) == "font_size 15\n")
        }
    }

    // MARK: - sync

    private let manifest = """
    [settings]
    active_profile = "work"

    [profiles.work]
    plugins = []

    [profiles.focus]
    plugins = []
    """

    private func syncFixture() throws -> ConfigDir {
        let dir = try tempConfigDir()
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
        _ = try ProfileStore(root: dir.profilesDir).create(try ProfileName(validating: "work"))
        try manifest.write(to: dir.manifestFile, atomically: true, encoding: .utf8)
        return dir
    }

    @Test func syncDeclinedAppliesNothing() throws {
        let dir = try syncFixture()

        var prompt = ""
        var logs: [String] = []
        try Synchronizer(
            configDir: dir,
            validator: StubValidator(.valid),
            reloader: ConfirmStubReloader(),
            confirm: { prompt = $0; return false }
        ).run { logs.append($0) }

        #expect(prompt.contains("sync will apply:"))
        #expect(logs.contains { $0.contains("Aborted") })
        #expect(fm.fileExists(atPath: dir.profilesDir.appendingPathComponent("focus").path) == false)
        #expect(fm.fileExists(atPath: dir.activeConf.path) == false)
        #expect(ActivePointer(url: dir.activePointerFile).get() == nil)
    }

    @Test func syncConfirmedApplies() throws {
        let dir = try syncFixture()

        try Synchronizer(
            configDir: dir,
            validator: StubValidator(.valid),
            reloader: ConfirmStubReloader(),
            confirm: { prompt in
                #expect(prompt.contains("Proceed? [y/N]"))
                return true
            }
        ).run { _ in }

        #expect(fm.fileExists(atPath: dir.profilesDir.appendingPathComponent("focus").path))
        #expect(fm.fileExists(atPath: dir.activeConf.path))
        #expect(ActivePointer(url: dir.activePointerFile).get() == "work")
    }

    @Test func syncWithoutConfirmClosureStaysUnprompted() throws {
        // nil confirm preserves the programmatic behavior (TUI, `update`, tests).
        let dir = try syncFixture()

        try Synchronizer(
            configDir: dir,
            validator: StubValidator(.valid),
            reloader: ConfirmStubReloader()
        ).run { _ in }

        #expect(fm.fileExists(atPath: dir.profilesDir.appendingPathComponent("focus").path))
        #expect(ActivePointer(url: dir.activePointerFile).get() == "work")
    }
}
