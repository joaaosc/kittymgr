import Foundation
import Testing
@testable import KittymgrCore

private final class StubReloader: Reloading, @unchecked Sendable {
    let outcome: ReloadOutcome
    private(set) var calls = 0
    init(_ outcome: ReloadOutcome = .reloaded) { self.outcome = outcome }
    func reload() -> ReloadOutcome { calls += 1; return outcome }
}

struct SamplePluginsTests {
    private let fileManager = FileManager.default

    @Test func seedsThemeSampleIdempotently() throws {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kittymgr-seed-\(UUID().uuidString)")
            .appendingPathComponent("plugins")

        try SamplePlugins.seed(into: root)
        let store = PluginStore(root: root)
        #expect(try store.list().map(\.name) == ["theme-sample"])
        #expect(store.priority(of: "theme-sample") == 50)

        // Idempotent: re-seeding does not duplicate or overwrite.
        try SamplePlugins.seed(into: root)
        #expect(try store.list().count == 1)
    }
}

struct PluginStoreTests {
    private let fileManager = FileManager.default

    private func makeStore() -> PluginStore {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("kittymgr-plugins-\(UUID().uuidString)")
            .appendingPathComponent("plugins")
        return PluginStore(root: root)
    }

    private func makePlugin(_ store: PluginStore, name: String, priority: Int?, files: [String]) throws {
        let dir = store.root.appendingPathComponent(name)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            try "# \(file)\n".write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        if let priority {
            try "priority=\(priority)\n".write(to: dir.appendingPathComponent("plugin.meta"), atomically: true, encoding: .utf8)
        }
    }

    @Test func listOrdersByPriorityThenName() throws {
        let store = makeStore()
        try makePlugin(store, name: "zeta", priority: 10, files: ["z.conf"])
        try makePlugin(store, name: "alpha", priority: 10, files: ["a.conf"])
        try makePlugin(store, name: "first", priority: 1, files: ["f.conf"])
        // Priority ascending, then name lexically.
        #expect(try store.list().map(\.name) == ["first", "alpha", "zeta"])
    }

    @Test func priorityDefaultsToZeroWhenMetaAbsent() throws {
        let store = makeStore()
        try makePlugin(store, name: "bare", priority: nil, files: ["b.conf"])
        #expect(store.priority(of: "bare") == 0)
    }

    @Test func confFilesAreLexicalAndConfOnly() throws {
        let store = makeStore()
        try makePlugin(store, name: "p", priority: 0, files: ["10.conf", "00.conf", "notes.txt"])
        #expect(try store.confFiles(in: "p") == ["00.conf", "10.conf"])
    }
}

struct IncludeBuilderTests {
    private let fileManager = FileManager.default

    private struct Env {
        let profileStore: ProfileStore
        let pluginStore: PluginStore
    }

    private func makeEnv() -> Env {
        let managed = fileManager.temporaryDirectory
            .appendingPathComponent("kittymgr-include-\(UUID().uuidString)")
            .appendingPathComponent("kittymgr")
        return Env(
            profileStore: ProfileStore(root: managed.appendingPathComponent("profiles")),
            pluginStore: PluginStore(root: managed.appendingPathComponent("plugins"))
        )
    }

    private func seedProfile(_ store: ProfileStore, _ name: String, files: [String]) throws {
        let dir = try store.create(try ProfileName(validating: name))
        for file in files {
            try "# \(file)\n".write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    private func seedPlugin(_ store: PluginStore, _ name: String, priority: Int, files: [String]) throws {
        let dir = store.root.appendingPathComponent(name)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            try "# \(file)\n".write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try "priority=\(priority)\n".write(to: dir.appendingPathComponent("plugin.meta"), atomically: true, encoding: .utf8)
    }

    @Test func ordersProfileBaseThenPluginsByPriority() throws {
        let env = makeEnv()
        try seedProfile(env.profileStore, "work", files: ["00-base.conf"])
        try seedPlugin(env.pluginStore, "theme", priority: 50, files: ["theme.conf"])
        try seedPlugin(env.pluginStore, "keys", priority: 10, files: ["keys.conf"])

        let includes = try IncludeBuilder.includes(
            profile: try ProfileName(validating: "work"),
            profileStore: env.profileStore,
            pluginStore: env.pluginStore,
            enabledPlugins: ["theme", "keys"]
        )
        // Profile base first, then plugins by ascending priority (keys=10 before theme=50).
        #expect(includes == [
            "profiles/work/00-base.conf",
            "plugins/keys/keys.conf",
            "plugins/theme/theme.conf",
        ])
    }

    @Test func ignoresDisabledPlugins() throws {
        let env = makeEnv()
        try seedProfile(env.profileStore, "work", files: ["base.conf"])
        try seedPlugin(env.pluginStore, "theme", priority: 50, files: ["theme.conf"])

        let includes = try IncludeBuilder.includes(
            profile: try ProfileName(validating: "work"),
            profileStore: env.profileStore,
            pluginStore: env.pluginStore,
            enabledPlugins: []
        )
        #expect(includes == ["profiles/work/base.conf"])
    }

    @Test func regenerationIsDeterministic() throws {
        let env = makeEnv()
        try seedProfile(env.profileStore, "work", files: ["base.conf"])
        try seedPlugin(env.pluginStore, "a", priority: 10, files: ["a.conf"])
        try seedPlugin(env.pluginStore, "b", priority: 10, files: ["b.conf"])

        let name = try ProfileName(validating: "work")
        let first = try IncludeBuilder.includes(profile: name, profileStore: env.profileStore, pluginStore: env.pluginStore, enabledPlugins: ["b", "a"])
        let second = try IncludeBuilder.includes(profile: name, profileStore: env.profileStore, pluginStore: env.pluginStore, enabledPlugins: ["a", "b"])
        #expect(first == second)
    }
}

struct PluginCommandTests {
    private let fileManager = FileManager.default
    private func silent(_ message: String) {}

    private struct Fixture {
        let profileStore: ProfileStore
        let pluginStore: PluginStore
        let pointer: ActivePointer
        let activeConf: URL
    }

    private func makeFixture() throws -> Fixture {
        let managed = fileManager.temporaryDirectory
            .appendingPathComponent("kittymgr-plugincmd-\(UUID().uuidString)")
            .appendingPathComponent("kittymgr")
        let fixture = Fixture(
            profileStore: ProfileStore(root: managed.appendingPathComponent("profiles")),
            pluginStore: PluginStore(root: managed.appendingPathComponent("plugins")),
            pointer: ActivePointer(url: managed.appendingPathComponent(".kittymgr-active")),
            activeConf: managed.appendingPathComponent("active.conf")
        )
        _ = try fixture.profileStore.create(try ProfileName(validating: "work"))
        try SamplePlugins.seed(into: fixture.pluginStore.root)
        return fixture
    }

    private func command(_ fixture: Fixture, _ action: PluginCommand.Action, profileOverride: String? = nil, reloader: any Reloading = StubReloader()) -> PluginCommand {
        PluginCommand(
            action: action,
            profileStore: fixture.profileStore,
            pluginStore: fixture.pluginStore,
            activePointer: fixture.pointer,
            activeConf: fixture.activeConf,
            profileOverride: profileOverride,
            reloader: reloader
        )
    }

    @Test func enableAddsToMetadataAndRegeneratesActiveProfile() throws {
        let fixture = try makeFixture()
        try fixture.pointer.set(try ProfileName(validating: "work"))

        try command(fixture, .enable("theme-sample")).run(log: silent)

        let metadata = fixture.profileStore.metadata(for: try ProfileName(validating: "work"))
        #expect(metadata.enabledPlugins == ["theme-sample"])
        let active = try String(contentsOf: fixture.activeConf, encoding: .utf8)
        #expect(active.contains("include plugins/theme-sample/theme.conf"))
    }

    @Test func disableRemovesResidualLines() throws {
        let fixture = try makeFixture()
        try fixture.pointer.set(try ProfileName(validating: "work"))
        try command(fixture, .enable("theme-sample")).run(log: silent)

        try command(fixture, .disable("theme-sample")).run(log: silent)

        let metadata = fixture.profileStore.metadata(for: try ProfileName(validating: "work"))
        #expect(metadata.enabledPlugins.isEmpty)
        let active = try String(contentsOf: fixture.activeConf, encoding: .utf8)
        #expect(active.contains("theme-sample") == false)
    }

    @Test func enableUnknownPluginFails() throws {
        let fixture = try makeFixture()
        try fixture.pointer.set(try ProfileName(validating: "work"))
        #expect(throws: ProfileError.notFound("ghost")) {
            try command(fixture, .enable("ghost")).run(log: silent)
        }
    }

    @Test func enableWithoutActiveOrOverrideFails() throws {
        let fixture = try makeFixture()
        #expect(throws: ProfileError.noActiveProfile) {
            try command(fixture, .enable("theme-sample")).run(log: silent)
        }
    }

    @Test func enableForNonActiveProfileDoesNotTouchActiveConf() throws {
        let fixture = try makeFixture()
        _ = try fixture.profileStore.create(try ProfileName(validating: "other"))
        try fixture.pointer.set(try ProfileName(validating: "work"))

        try command(fixture, .enable("theme-sample"), profileOverride: "other").run(log: silent)

        // "other" metadata updated; active.conf (work) not generated by this call.
        #expect(fixture.profileStore.metadata(for: try ProfileName(validating: "other")).enabledPlugins == ["theme-sample"])
        #expect(fileManager.fileExists(atPath: fixture.activeConf.path) == false)
    }
}
