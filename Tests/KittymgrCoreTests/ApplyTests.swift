import Foundation
import Testing
@testable import KittymgrCore

private final class CountingReloader: Reloading, @unchecked Sendable {
    let outcome: ReloadOutcome
    private(set) var calls = 0
    init(_ outcome: ReloadOutcome = .reloaded) { self.outcome = outcome }
    func reload() -> ReloadOutcome { calls += 1; return outcome }
}

struct ApplyTransactionTests {
    private let fm = FileManager.default

    private func makeConfigDir() throws -> ConfigDir {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-apply-\(UUID().uuidString)")
        let dir = ConfigDir(url: root)
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
        try "font_size 12\n".write(to: dir.activeConf, atomically: true, encoding: .utf8)
        return dir
    }

    private func transaction(_ dir: ConfigDir, validator: ConfigValidating, reloader: Reloading) -> ApplyTransaction {
        ApplyTransaction(snapshotStore: SnapshotStore(configDir: dir), validator: validator, reloader: reloader)
    }

    @Test func validChangeIsAppliedAndReloaded() throws {
        let dir = try makeConfigDir()
        let reloader = CountingReloader(.reloaded)
        let plan = ApplyPlan(writes: [dir.relativePath(of: dir.activeConf): "font_size 16\n"])

        let result = try transaction(dir, validator: StubValidator(.valid), reloader: reloader)
            .apply(plan: plan, validationContent: "font_size 16\n", dryRun: false, log: { _ in })

        #expect(result.status == .applied)
        #expect(reloader.calls == 1)
        #expect(try String(contentsOf: dir.activeConf, encoding: .utf8) == "font_size 16\n")
    }

    @Test func invalidChangeRollsBackByteForByte() throws {
        let dir = try makeConfigDir()
        let before = try Data(contentsOf: dir.activeConf)
        let reloader = CountingReloader(.reloaded)
        let plan = ApplyPlan(writes: [dir.relativePath(of: dir.activeConf): "font_size NOPE\n"])

        #expect(throws: SafetyError.self) {
            try transaction(dir, validator: StubValidator(.invalid(diagnostics: "bad value")), reloader: reloader)
                .apply(plan: plan, validationContent: "font_size NOPE\n", dryRun: false, log: { _ in })
        }

        // Managed surface restored from the pre-apply snapshot; no reload triggered.
        #expect(try Data(contentsOf: dir.activeConf) == before)
        #expect(reloader.calls == 0)
    }

    @Test func skippedValidationKeepsChange() throws {
        let dir = try makeConfigDir()
        let plan = ApplyPlan(writes: [dir.relativePath(of: dir.activeConf): "font_size 20\n"])

        let result = try transaction(dir, validator: StubValidator(.skipped(reason: "no kitty")), reloader: CountingReloader())
            .apply(plan: plan, validationContent: "font_size 20\n", dryRun: false, log: { _ in })

        #expect(result.status == .applied)
        #expect(try String(contentsOf: dir.activeConf, encoding: .utf8) == "font_size 20\n")
    }

    @Test func dryRunPrintsDiffWithoutWritingOrReloading() throws {
        let dir = try makeConfigDir()
        let before = try Data(contentsOf: dir.activeConf)
        let reloader = CountingReloader(.reloaded)
        let plan = ApplyPlan(writes: [dir.relativePath(of: dir.activeConf): "font_size 16\n"])

        var out: [String] = []
        let result = try transaction(dir, validator: StubValidator(.valid), reloader: reloader)
            .apply(plan: plan, validationContent: "font_size 16\n", dryRun: true) { out.append($0) }

        let joined = out.joined(separator: "\n")
        #expect(result.status == .previewed)
        #expect(joined.contains("[dry-run]"))
        #expect(joined.contains("-font_size 12"))
        #expect(joined.contains("+font_size 16"))
        #expect(try Data(contentsOf: dir.activeConf) == before)  // untouched
        #expect(reloader.calls == 0)
        // No snapshot is taken in dry-run.
        #expect(SnapshotStore(configDir: dir).list().isEmpty)
    }
}

struct ApplyCommandTests {
    private let fm = FileManager.default

    private func makeConfigDir(activeProfile: String, files: [String: String]) throws -> ConfigDir {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-applycmd-\(UUID().uuidString)")
        let dir = ConfigDir(url: root)
        let store = ProfileStore(root: dir.profilesDir)
        let name = try ProfileName(validating: activeProfile)
        let profileDir = try store.create(name)
        for (file, content) in files {
            try content.write(to: profileDir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try ActivePointer(url: dir.activePointerFile).set(name)
        return dir
    }

    @Test func recomposesActiveProfileThroughTransaction() throws {
        let dir = try makeConfigDir(activeProfile: "work", files: ["00-base.conf": "font_size 14\n"])

        try ApplyCommand(
            configDir: dir,
            dryRun: false,
            validator: StubValidator(.valid),
            reloader: CountingReloader()
        ).run(log: { _ in })

        let active = try String(contentsOf: dir.activeConf, encoding: .utf8)
        #expect(active.contains("include profiles/work/00-base.conf"))
    }

    @Test func failsWhenNoActiveProfile() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-applycmd-\(UUID().uuidString)")
        let dir = ConfigDir(url: root)
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
        #expect(throws: ProfileError.noActiveProfile) {
            try ApplyCommand(configDir: dir, validator: StubValidator(.valid), reloader: CountingReloader())
                .run(log: { _ in })
        }
    }
}
