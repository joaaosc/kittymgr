import Foundation
import Testing
@testable import KittymgrCore

struct ConflictDetectorTests {
    @Test func detectsDuplicateKeymapAcrossLayers() {
        let layers = [
            ConfigLayer(label: "profiles/work/base.conf", content: "map ctrl+c copy_to_clipboard\n"),
            ConfigLayer(label: "plugins/keys/keys.conf", content: "map ctrl+c discard_event\n"),
        ]
        let conflicts = ConflictDetector.detect(layers)
        #expect(conflicts == [
            .duplicateKeymap(chord: "ctrl+c", sources: ["profiles/work/base.conf", "plugins/keys/keys.conf"]),
        ])
    }

    @Test func detectsShadowedOptionWithEffectiveValue() {
        let layers = [
            ConfigLayer(label: "profiles/work/base.conf", content: "font_size 12\n"),
            ConfigLayer(label: "plugins/theme/theme.conf", content: "font_size 16\n"),
        ]
        let conflicts = ConflictDetector.detect(layers)
        #expect(conflicts == [
            .shadowedOption(
                name: "font_size",
                sources: ["profiles/work/base.conf", "plugins/theme/theme.conf"],
                effectiveSource: "plugins/theme/theme.conf",
                effectiveValue: "16"
            ),
        ])
    }

    @Test func noConflictForDistinctKeysAndOptions() {
        let layers = [
            ConfigLayer(label: "a.conf", content: "map ctrl+c copy_to_clipboard\nfont_size 12\n"),
            ConfigLayer(label: "b.conf", content: "map ctrl+v paste\nbackground #000000\n"),
        ]
        #expect(ConflictDetector.detect(layers).isEmpty)
    }

    @Test func ignoresCommentsAndIncludes() {
        let layers = [
            ConfigLayer(label: "a.conf", content: "# font_size 12\ninclude other.conf\n"),
            ConfigLayer(label: "b.conf", content: "# font_size 12\ninclude other.conf\n"),
        ]
        #expect(ConflictDetector.detect(layers).isEmpty)
    }
}

struct CheckCommandTests {
    private let fileManager = FileManager.default
    private func silent(_ message: String) {}

    private struct Fixture {
        let profileStore: ProfileStore
        let pluginStore: PluginStore
    }

    private func makeFixture() -> Fixture {
        let managed = fileManager.temporaryDirectory
            .appendingPathComponent("kittymgr-check-\(UUID().uuidString)")
            .appendingPathComponent("kittymgr")
        return Fixture(
            profileStore: ProfileStore(root: managed.appendingPathComponent("profiles")),
            pluginStore: PluginStore(root: managed.appendingPathComponent("plugins"))
        )
    }

    private func seedProfile(_ store: ProfileStore, _ name: String, files: [String: String]) throws {
        let dir = try store.create(try ProfileName(validating: name))
        for (file, content) in files {
            try content.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    @Test func cleanProfilePasses() throws {
        let fixture = makeFixture()
        try seedProfile(fixture.profileStore, "clean", files: ["base.conf": "font_size 12\n"])
        let passed = try CheckCommand(
            profileStore: fixture.profileStore,
            pluginStore: fixture.pluginStore,
            rawName: "clean",
            validator: StubValidator(.valid)
        ).run(log: silent)
        #expect(passed)
    }

    @Test func invalidConfigFails() throws {
        let fixture = makeFixture()
        try seedProfile(fixture.profileStore, "broken", files: ["base.conf": "font_size oops\n"])
        let passed = try CheckCommand(
            profileStore: fixture.profileStore,
            pluginStore: fixture.pluginStore,
            rawName: "broken",
            validator: StubValidator(.invalid(diagnostics: "Bad value for font_size"))
        ).run(log: silent)
        #expect(passed == false)
    }

    @Test func conflictsAreWarningsNotFailures() throws {
        let fixture = makeFixture()
        try seedProfile(fixture.profileStore, "dup", files: [
            "a.conf": "map ctrl+c copy_to_clipboard\n",
            "b.conf": "map ctrl+c discard_event\n",
        ])
        var captured: [String] = []
        let passed = try CheckCommand(
            profileStore: fixture.profileStore,
            pluginStore: fixture.pluginStore,
            rawName: "dup",
            validator: StubValidator(.valid)
        ).run { captured.append($0) }
        #expect(passed)
        #expect(captured.contains { $0.contains("warning:") && $0.contains("ctrl+c") })
    }
}

struct SwitchGateTests {
    private let fileManager = FileManager.default
    private func silent(_ message: String) {}

    private struct Fixture {
        let profileStore: ProfileStore
        let pluginStore: PluginStore
        let pointer: ActivePointer
        let activeConf: URL
    }

    private func makeFixture() -> Fixture {
        let managed = fileManager.temporaryDirectory
            .appendingPathComponent("kittymgr-gate-\(UUID().uuidString)")
            .appendingPathComponent("kittymgr")
        return Fixture(
            profileStore: ProfileStore(root: managed.appendingPathComponent("profiles")),
            pluginStore: PluginStore(root: managed.appendingPathComponent("plugins")),
            pointer: ActivePointer(url: managed.appendingPathComponent(".kittymgr-active")),
            activeConf: managed.appendingPathComponent("active.conf")
        )
    }

    private func seed(_ store: ProfileStore, _ name: String, files: [String: String]) throws {
        let dir = try store.create(try ProfileName(validating: name))
        for (file, content) in files {
            try content.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
    }

    private func command(_ f: Fixture, profile: String, force: Bool, validator: ValidationResult) -> SwitchCommand {
        SwitchCommand(
            profileStore: f.profileStore,
            pluginStore: f.pluginStore,
            activePointer: f.pointer,
            activeConf: f.activeConf,
            rawName: profile,
            force: force,
            validator: StubValidator(validator),
            reloader: StubReloader(.reloaded)
        )
    }

    @Test func invalidConfigBlocksSwitch() throws {
        let fixture = makeFixture()
        try seed(fixture.profileStore, "p", files: ["base.conf": "font_size oops\n"])
        #expect(throws: SafetyError.self) {
            try command(fixture, profile: "p", force: false, validator: .invalid(diagnostics: "Bad value")).run(log: silent)
        }
        #expect(fixture.pointer.get() == nil)
    }

    @Test func conflictsBlockWithoutForce() throws {
        let fixture = makeFixture()
        try seed(fixture.profileStore, "p", files: [
            "a.conf": "map ctrl+c copy_to_clipboard\n",
            "b.conf": "map ctrl+c discard_event\n",
        ])
        #expect(throws: SafetyError.self) {
            try command(fixture, profile: "p", force: false, validator: .valid).run(log: silent)
        }
        #expect(fixture.pointer.get() == nil)
    }

    @Test func conflictsProceedWithForce() throws {
        let fixture = makeFixture()
        try seed(fixture.profileStore, "p", files: [
            "a.conf": "map ctrl+c copy_to_clipboard\n",
            "b.conf": "map ctrl+c discard_event\n",
        ])
        try command(fixture, profile: "p", force: true, validator: .valid).run(log: silent)
        #expect(fixture.pointer.get() == "p")
    }

    @Test func validConflictFreeProfileSwitches() throws {
        let fixture = makeFixture()
        try seed(fixture.profileStore, "p", files: ["base.conf": "font_size 12\n"])
        try command(fixture, profile: "p", force: false, validator: .valid).run(log: silent)
        #expect(fixture.pointer.get() == "p")
    }
}

private final class StubReloader: Reloading, @unchecked Sendable {
    let outcome: ReloadOutcome
    init(_ outcome: ReloadOutcome) { self.outcome = outcome }
    func reload() -> ReloadOutcome { outcome }
}
