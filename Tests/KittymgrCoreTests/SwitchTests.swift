import Foundation
import Testing
@testable import KittymgrCore

private final class StubReloader: Reloading, @unchecked Sendable {
    let outcome: ReloadOutcome
    private(set) var calls = 0
    init(_ outcome: ReloadOutcome) { self.outcome = outcome }
    func reload() -> ReloadOutcome {
        calls += 1
        return outcome
    }
}

struct ActiveConfTests {
    @Test func rendersIncludeLinesInOrder() {
        let content = ActiveConf.render(
            profile: "work",
            includes: ["profiles/work/00-base.conf", "profiles/work/10-theme.conf"]
        )
        #expect(content.contains("# Active profile: work"))
        #expect(content.contains("include profiles/work/00-base.conf\ninclude profiles/work/10-theme.conf"))
    }

    @Test func rendersPlaceholderWhenEmpty() {
        let content = ActiveConf.render(profile: "empty", includes: [])
        #expect(content.contains("# Active profile: empty"))
        #expect(content.contains("no .conf files") == true)
        #expect(content.contains("include ") == false)
    }
}

struct ActivePointerTests {
    private let fileManager = FileManager.default

    private func makePointer() -> ActivePointer {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("kittymgr-active-\(UUID().uuidString)")
            .appendingPathComponent("kittymgr/.kittymgr-active")
        return ActivePointer(url: url)
    }

    @Test func getReturnsNilWhenUnset() {
        #expect(makePointer().get() == nil)
    }

    @Test func setThenGetRoundTrips() throws {
        let pointer = makePointer()
        try pointer.set(try ProfileName(validating: "work"))
        #expect(pointer.get() == "work")
    }

    @Test func clearRemovesPointer() throws {
        let pointer = makePointer()
        try pointer.set(try ProfileName(validating: "work"))
        pointer.clear()
        #expect(pointer.get() == nil)
    }
}

struct SwitchCommandTests {
    private let fileManager = FileManager.default

    private struct Fixture {
        let profileStore: ProfileStore
        let pluginStore: PluginStore
        let pointer: ActivePointer
        let activeConf: URL
    }

    private func makeFixture() throws -> Fixture {
        let managed = fileManager.temporaryDirectory
            .appendingPathComponent("kittymgr-switch-\(UUID().uuidString)")
            .appendingPathComponent("kittymgr")
        return Fixture(
            profileStore: ProfileStore(root: managed.appendingPathComponent("profiles")),
            pluginStore: PluginStore(root: managed.appendingPathComponent("plugins")),
            pointer: ActivePointer(url: managed.appendingPathComponent(".kittymgr-active")),
            activeConf: managed.appendingPathComponent("active.conf")
        )
    }

    private func silent(_ message: String) {}

    private func makeCommand(_ fixture: Fixture, profile: String, reloader: any Reloading) -> SwitchCommand {
        SwitchCommand(
            profileStore: fixture.profileStore,
            pluginStore: fixture.pluginStore,
            activePointer: fixture.pointer,
            activeConf: fixture.activeConf,
            rawName: profile,
            validator: StubValidator(.valid),
            reloader: reloader
        )
    }

    private func seed(_ store: ProfileStore, profile: String, files: [String]) throws {
        let name = try ProfileName(validating: profile)
        let dir = try store.create(name)
        for file in files {
            try "# \(file)\n".write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    @Test func switchUpdatesActiveConfAndPointer() throws {
        let fixture = try makeFixture()
        try seed(fixture.profileStore, profile: "work", files: ["10-theme.conf", "00-base.conf"])
        let reloader = StubReloader(.reloaded)

        try makeCommand(fixture, profile: "work", reloader: reloader).run(log: silent)

        let content = try String(contentsOf: fixture.activeConf, encoding: .utf8)
        // Deterministic lexical order: 00 before 10.
        #expect(content.contains("include profiles/work/00-base.conf\ninclude profiles/work/10-theme.conf"))
        #expect(fixture.pointer.get() == "work")
        #expect(reloader.calls == 1)
    }

    @Test func switchIsNonFatalWhenReloadUnavailable() throws {
        let fixture = try makeFixture()
        try seed(fixture.profileStore, profile: "work", files: ["a.conf"])

        try makeCommand(fixture, profile: "work", reloader: StubReloader(.unavailable(reason: "remote control off")))
            .run(log: silent)

        #expect(fixture.pointer.get() == "work")
        #expect(fileManager.fileExists(atPath: fixture.activeConf.path))
    }

    @Test func switchToUnknownProfileLeavesActiveStateUnchanged() throws {
        let fixture = try makeFixture()
        try seed(fixture.profileStore, profile: "work", files: ["a.conf"])
        try makeCommand(fixture, profile: "work", reloader: StubReloader(.reloaded)).run(log: silent)

        #expect(throws: ProfileError.notFound("ghost")) {
            try makeCommand(fixture, profile: "ghost", reloader: StubReloader(.reloaded)).run(log: self.silent)
        }
        // Active state still points at the previously switched profile.
        #expect(fixture.pointer.get() == "work")
    }

    @Test func dryRunSwitchPreviewsWithoutWritingOrRecording() throws {
        let fixture = try makeFixture()
        try seed(fixture.profileStore, profile: "work", files: ["00-base.conf"])

        var captured: [String] = []
        try SwitchCommand(
            profileStore: fixture.profileStore,
            pluginStore: fixture.pluginStore,
            activePointer: fixture.pointer,
            activeConf: fixture.activeConf,
            rawName: "work",
            dryRun: true,
            validator: StubValidator(.valid),
            reloader: StubReloader(.reloaded)
        ).run { captured.append($0) }

        #expect(captured.joined(separator: "\n").contains("[dry-run]"))
        #expect(fixture.pointer.get() == nil)
        #expect(fileManager.fileExists(atPath: fixture.activeConf.path) == false)
    }

    @Test func switchEmptyProfileWritesNoIncludes() throws {
        let fixture = try makeFixture()
        try seed(fixture.profileStore, profile: "empty", files: [])
        try makeCommand(fixture, profile: "empty", reloader: StubReloader(.reloaded)).run(log: silent)

        let content = try String(contentsOf: fixture.activeConf, encoding: .utf8)
        #expect(content.contains("include ") == false)
        #expect(fixture.pointer.get() == "empty")
    }

    @Test func switchResolvesCasingToOnDiskCasing() throws {
        let fixture = try makeFixture()
        try seed(fixture.profileStore, profile: "Work", files: ["a.conf"])
        let reloader = StubReloader(.reloaded)

        try makeCommand(fixture, profile: "work", reloader: reloader).run(log: silent)

        #expect(fixture.pointer.get() == "Work")
    }
}

struct CurrentCommandTests {
    private let fileManager = FileManager.default

    private func makePointer() -> ActivePointer {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("kittymgr-current-\(UUID().uuidString)")
            .appendingPathComponent("kittymgr/.kittymgr-active")
        return ActivePointer(url: url)
    }

    @Test func printsActiveName() throws {
        let pointer = makePointer()
        try pointer.set(try ProfileName(validating: "work"))
        var captured: [String] = []
        try CurrentCommand(activePointer: pointer).run { captured.append($0) }
        #expect(captured == ["work"])
    }

    @Test func reportsNoneWhenUnset() throws {
        var captured: [String] = []
        try CurrentCommand(activePointer: makePointer()).run { captured.append($0) }
        #expect(captured.count == 1)
        #expect(captured[0].contains("No active profile"))
    }
}
