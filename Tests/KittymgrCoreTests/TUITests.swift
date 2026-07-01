import Foundation
import Testing
@testable import KittymgrCore

private final class StubReloader: Reloading, @unchecked Sendable {
    func reload() -> ReloadOutcome { .reloaded }
}

struct PickerTests {
    private let fileManager = FileManager.default

    private struct Fixture {
        let profileStore: ProfileStore
        let pluginStore: PluginStore
        let pointer: ActivePointer
        let activeConf: URL
    }

    private func makeFixture() throws -> Fixture {
        let managed = fileManager.temporaryDirectory
            .appendingPathComponent("kittymgr-tui-\(UUID().uuidString)")
            .appendingPathComponent("managed")
        let fixture = Fixture(
            profileStore: ProfileStore(root: managed.appendingPathComponent("profiles")),
            pluginStore: PluginStore(root: managed.appendingPathComponent("plugins")),
            pointer: ActivePointer(url: managed.appendingPathComponent(".kittymgr-active")),
            activeConf: managed.appendingPathComponent("active.conf")
        )
        return fixture
    }

    private func makePicker(_ f: Fixture) -> Picker {
        Picker(
            profileStore: f.profileStore,
            pluginStore: f.pluginStore,
            activePointer: f.pointer,
            activeConf: f.activeConf,
            validator: StubValidator(.valid),
            reloader: StubReloader()
        )
    }

    /// Drive the picker with a scripted list of input lines, capturing output.
    private func drive(_ picker: Picker, inputs: [String]) throws -> [String] {
        var queue = inputs
        var output: [String] = []
        try picker.run(
            read: { queue.isEmpty ? nil : queue.removeFirst() },
            write: { output.append($0) }
        )
        return output
    }

    @Test func listsProfilesAndMarksActive() throws {
        let fixture = try makeFixture()
        _ = try fixture.profileStore.create(try ProfileName(validating: "work"))
        _ = try fixture.profileStore.create(try ProfileName(validating: "dev"))
        try fixture.pointer.set(try ProfileName(validating: "work"))

        let output = try drive(makePicker(fixture), inputs: ["q"])
        let joined = output.joined(separator: "\n")
        #expect(joined.contains("work *"))
        #expect(joined.contains("dev"))
    }

    @Test func selectingProfileSwitchesAndReloads() throws {
        let fixture = try makeFixture()
        let dir = try fixture.profileStore.create(try ProfileName(validating: "work"))
        try "font_size 12\n".write(to: dir.appendingPathComponent("base.conf"), atomically: true, encoding: .utf8)

        // Profiles list is sorted; "work" is index 1.
        _ = try drive(makePicker(fixture), inputs: ["1", "q"])

        #expect(fixture.pointer.get() == "work")
        #expect(fileManager.fileExists(atPath: fixture.activeConf.path))
    }

    @Test func togglingPluginUpdatesEnabledSet() throws {
        let fixture = try makeFixture()
        _ = try fixture.profileStore.create(try ProfileName(validating: "work"))
        try SamplePlugins.seed(into: fixture.pluginStore.root)
        try fixture.pointer.set(try ProfileName(validating: "work"))

        _ = try drive(makePicker(fixture), inputs: ["t theme-sample", "q"])
        #expect(fixture.profileStore.metadata(for: try ProfileName(validating: "work")).enabledPlugins == ["theme-sample"])

        // Toggling again disables it.
        _ = try drive(makePicker(fixture), inputs: ["t theme-sample", "q"])
        #expect(fixture.profileStore.metadata(for: try ProfileName(validating: "work")).enabledPlugins.isEmpty)
    }

    @Test func quittingWithoutSelectingMakesNoChanges() throws {
        let fixture = try makeFixture()
        _ = try fixture.profileStore.create(try ProfileName(validating: "work"))

        _ = try drive(makePicker(fixture), inputs: ["q"])
        #expect(fixture.pointer.get() == nil)
        #expect(fileManager.fileExists(atPath: fixture.activeConf.path) == false)
    }

    @Test func switchThemeFromPicker() throws {
        let fixture = try makeFixture()
        let dir = try fixture.profileStore.create(try ProfileName(validating: "work"))
        try "font_size 12\n".write(to: dir.appendingPathComponent("base.conf"), atomically: true, encoding: .utf8)
        try fixture.pointer.set(try ProfileName(validating: "work"))

        // Install a theme file directly under managed/themes/.
        let themesDir = fixture.activeConf.deletingLastPathComponent().appendingPathComponent("themes")
        try fileManager.createDirectory(at: themesDir, withIntermediateDirectories: true)
        try "background #282828\n".write(to: themesDir.appendingPathComponent("gruvbox.conf"), atomically: true, encoding: .utf8)

        _ = try drive(makePicker(fixture), inputs: ["theme gruvbox", "q"])
        let active = try String(contentsOf: fixture.activeConf, encoding: .utf8)
        #expect(active.contains("include themes/gruvbox.conf"))
    }

    @Test func createSnapshotFromPicker() throws {
        let fixture = try makeFixture()
        _ = try fixture.profileStore.create(try ProfileName(validating: "work"))

        _ = try drive(makePicker(fixture), inputs: ["snap demo", "q"])

        let configDir = ConfigDir(url: fixture.activeConf.deletingLastPathComponent().deletingLastPathComponent())
        #expect(SnapshotStore(configDir: configDir).list().contains { $0.label == "demo" })
    }

    @Test func restorePreviewShowsDiffWithoutApplying() throws {
        let fixture = try makeFixture()
        let dir = try fixture.profileStore.create(try ProfileName(validating: "work"))
        let base = dir.appendingPathComponent("base.conf")
        try "font_size 12\n".write(to: base, atomically: true, encoding: .utf8)

        let configDir = ConfigDir(url: fixture.activeConf.deletingLastPathComponent().deletingLastPathComponent())
        let snapshot = try SnapshotStore(configDir: configDir).create(label: "pre")
        try "font_size 99\n".write(to: base, atomically: true, encoding: .utf8)

        // Preview: prints a diff, changes nothing.
        let preview = try drive(makePicker(fixture), inputs: ["restore \(snapshot.id)", "q"]).joined(separator: "\n")
        #expect(preview.contains("[dry-run]"))
        #expect(try String(contentsOf: base, encoding: .utf8) == "font_size 99\n")

        // Apply: restores the snapshot.
        _ = try drive(makePicker(fixture), inputs: ["restore! \(snapshot.id)", "q"])
        #expect(try String(contentsOf: base, encoding: .utf8) == "font_size 12\n")
    }

    @Test func conflictBlocksSelectionUntilForced() throws {
        let fixture = try makeFixture()
        let dir = try fixture.profileStore.create(try ProfileName(validating: "work"))
        try "map ctrl+c copy_to_clipboard\n".write(to: dir.appendingPathComponent("a.conf"), atomically: true, encoding: .utf8)
        try "map ctrl+c discard_event\n".write(to: dir.appendingPathComponent("b.conf"), atomically: true, encoding: .utf8)

        // Plain select is blocked by the conflict; pointer stays unset.
        let output = try drive(makePicker(fixture), inputs: ["1", "q"])
        #expect(output.joined(separator: "\n").contains("Blocked"))
        #expect(fixture.pointer.get() == nil)

        // Force select proceeds.
        _ = try drive(makePicker(fixture), inputs: ["f 1", "q"])
        #expect(fixture.pointer.get() == "work")
    }
}
