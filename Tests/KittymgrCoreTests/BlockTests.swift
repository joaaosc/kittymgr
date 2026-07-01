import Foundation
import Testing
@testable import KittymgrCore

private final class StubReloader: Reloading, @unchecked Sendable {
    func reload() -> ReloadOutcome { .reloaded }
}

struct BlockCommandTests {
    private let fm = FileManager.default

    private func makeConfigDir(activeProfile: String? = "work") throws -> ConfigDir {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-block-\(UUID().uuidString)")
        let dir = ConfigDir(url: root)
        let profileStore = ProfileStore(root: dir.profilesDir)
        let profileDir = try profileStore.create(try ProfileName(validating: "work"))
        try "font_size 12\n".write(to: profileDir.appendingPathComponent("00-base.conf"), atomically: true, encoding: .utf8)
        if let activeProfile {
            try ActivePointer(url: dir.activePointerFile).set(try ProfileName(validating: activeProfile))
        }
        return dir
    }

    private func command(_ dir: ConfigDir, _ action: BlockCommand.Action, dryRun: Bool = false) -> BlockCommand {
        BlockCommand(action: action, configDir: dir, dryRun: dryRun, validator: StubValidator(.valid), reloader: StubReloader())
    }

    private func activeConf(_ dir: ConfigDir) -> String {
        (try? String(contentsOf: dir.activeConf, encoding: .utf8)) ?? ""
    }

    @Test func installThenSwitchThemeComposesIntoActiveConf() throws {
        let dir = try makeConfigDir()
        try command(dir, .themeInstall(name: "gruvbox", content: "background #282828\n")).run(log: { _ in })
        #expect(fm.fileExists(atPath: dir.managedDir.appendingPathComponent("themes/gruvbox.conf").path))

        try command(dir, .themeSwitch(name: "gruvbox")).run(log: { _ in })
        #expect(activeConf(dir).contains("include themes/gruvbox.conf"))
    }

    @Test func themesAreMutuallyExclusive() throws {
        let dir = try makeConfigDir()
        try command(dir, .themeInstall(name: "light", content: "background #ffffff\n")).run(log: { _ in })
        try command(dir, .themeInstall(name: "dark", content: "background #000000\n")).run(log: { _ in })

        try command(dir, .themeSwitch(name: "light")).run(log: { _ in })
        try command(dir, .themeSwitch(name: "dark")).run(log: { _ in })

        let conf = activeConf(dir)
        #expect(conf.contains("include themes/dark.conf"))
        #expect(conf.contains("include themes/light.conf") == false)
    }

    @Test func switchingUninstalledThemeThrows() throws {
        let dir = try makeConfigDir()
        #expect(throws: ProfileError.notFound("ghost")) {
            try command(dir, .themeSwitch(name: "ghost")).run(log: { _ in })
        }
    }

    @Test func keyAddCreatesOwnIncludeAndRemoveRestores() throws {
        let dir = try makeConfigDir()
        try command(dir, .keyAdd(chord: "ctrl+shift+e", action: "launch")).run(log: { _ in })

        let keyFile = dir.managedDir.appendingPathComponent("keys/ctrl-shift-e.conf")
        #expect(fm.fileExists(atPath: keyFile.path))
        #expect((try? String(contentsOf: keyFile, encoding: .utf8)) == "map ctrl+shift+e launch\n")
        #expect(activeConf(dir).contains("include keys/ctrl-shift-e.conf"))

        try command(dir, .keyRemove(chord: "ctrl+shift+e")).run(log: { _ in })
        #expect(fm.fileExists(atPath: keyFile.path) == false)
        #expect(activeConf(dir).contains("include keys/ctrl-shift-e.conf") == false)
    }

    @Test func snippetAddIsAdditive() throws {
        let dir = try makeConfigDir()
        try command(dir, .snippetAdd(name: "tabs", content: "tab_bar_style powerline\n")).run(log: { _ in })
        try command(dir, .snippetAdd(name: "cursor", content: "cursor_shape beam\n")).run(log: { _ in })
        let conf = activeConf(dir)
        #expect(conf.contains("include snippets/tabs.conf"))
        #expect(conf.contains("include snippets/cursor.conf"))
    }

    @Test func blocksPersistAcrossProfileSwitch() throws {
        let dir = try makeConfigDir()
        try command(dir, .themeInstall(name: "gruvbox", content: "background #282828\n")).run(log: { _ in })
        try command(dir, .themeSwitch(name: "gruvbox")).run(log: { _ in })

        // A second profile that switches in must still carry the active theme.
        _ = try ProfileStore(root: dir.profilesDir).create(try ProfileName(validating: "focus"))
        try SwitchCommand(
            profileStore: ProfileStore(root: dir.profilesDir),
            pluginStore: PluginStore(root: dir.pluginsDir),
            activePointer: ActivePointer(url: dir.activePointerFile),
            activeConf: dir.activeConf,
            rawName: "focus",
            validator: StubValidator(.valid),
            reloader: StubReloader()
        ).run(log: { _ in })

        #expect(activeConf(dir).contains("include themes/gruvbox.conf"))
    }

    @Test func dryRunThemeSwitchWritesNothing() throws {
        let dir = try makeConfigDir()
        try command(dir, .themeInstall(name: "gruvbox", content: "background #282828\n")).run(log: { _ in })
        let before = activeConf(dir)

        var out: [String] = []
        try command(dir, .themeSwitch(name: "gruvbox"), dryRun: true).run { out.append($0) }

        #expect(out.joined(separator: "\n").contains("[dry-run]"))
        #expect(fm.fileExists(atPath: dir.managedDir.appendingPathComponent(".kittymgr-theme").path) == false)
        #expect(activeConf(dir) == before)
    }

    @Test func installWithoutActiveProfileStillStoresTheme() throws {
        let dir = try makeConfigDir(activeProfile: nil)
        try command(dir, .themeInstall(name: "solarized", content: "background #002b36\n")).run(log: { _ in })
        #expect(fm.fileExists(atPath: dir.managedDir.appendingPathComponent("themes/solarized.conf").path))
    }
}
