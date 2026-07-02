import Foundation
import Testing
@testable import KittymgrCore

private struct FakeProbe: EnvironmentProbing {
    var kitty = true
    var git = true
    var remote = true
    func toolAvailable(_ tool: String) -> Bool { tool == "git" ? git : kitty }
    func remoteControlResponds() -> Bool { remote }
}

struct DoctorCommandTests {
    private let fm = FileManager.default

    /// An initialized managed layer with the guarded block in kitty.conf.
    private func makeConfig() throws -> ConfigDir {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-doctor-\(UUID().uuidString)")
        let dir = ConfigDir(url: root)
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
        try Guard.insert(into: "").write(to: dir.kittyConf, atomically: true, encoding: .utf8)
        return dir
    }

    @Test func healthyEnvironmentReportsNoFailures() throws {
        let dir = try makeConfig()
        var out: [String] = []
        let ok = DoctorCommand(configDir: dir, probe: FakeProbe()).run { out.append($0) }

        #expect(ok)
        #expect(out.contains { $0.contains("[OK] managed layer") })
        #expect(out.contains { $0.contains("[OK] kitty.conf block") })
        #expect(out.contains { $0.contains("0 failure(s)") })
    }

    @Test func missingToolsWarnButDoNotFail() throws {
        let dir = try makeConfig()
        var out: [String] = []
        let ok = DoctorCommand(configDir: dir, probe: FakeProbe(kitty: false, git: false, remote: false))
            .run { out.append($0) }

        #expect(ok)  // WARN is not FAIL.
        #expect(out.contains { $0.contains("[WARN] kitty") })
        #expect(out.contains { $0.contains("[WARN] git") })
        #expect(out.contains { $0.contains("[WARN] remote control") })
    }

    @Test func missingManagedLayerWarns() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-doctor-\(UUID().uuidString)")
        let dir = ConfigDir(url: root)  // nothing initialized
        var out: [String] = []
        let ok = DoctorCommand(configDir: dir, probe: FakeProbe()).run { out.append($0) }

        #expect(ok)
        #expect(out.contains { $0.contains("[WARN] managed layer") })
    }

    @Test func corruptBackupObjectFails() throws {
        let dir = try makeConfig()
        try "font_size 12\n".write(to: dir.managedDir.appendingPathComponent("active.conf"), atomically: true, encoding: .utf8)
        try SnapshotStore(configDir: dir).create(label: "seed")
        // Corrupt the store: drop the backing objects but keep the snapshot manifest.
        let objects = dir.backupsDir.appendingPathComponent("objects")
        for file in try fm.contentsOfDirectory(at: objects, includingPropertiesForKeys: nil) {
            try fm.removeItem(at: file)
        }

        var out: [String] = []
        let ok = DoctorCommand(configDir: dir, probe: FakeProbe()).run { out.append($0) }

        #expect(ok == false)
        #expect(out.contains { $0.contains("[FAIL] backups") })
    }
}
