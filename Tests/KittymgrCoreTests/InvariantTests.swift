import Foundation
import Testing
@testable import KittymgrCore

private final class R2Reloader: Reloading, @unchecked Sendable {
    func reload() -> ReloadOutcome { .reloaded }
}

private final class R2Fetcher: SourceFetching, @unchecked Sendable {
    let root: URL
    private(set) var invalidations = 0

    init(root: URL) {
        self.root = root
    }

    func fetch(_ source: Source) throws -> FetchedSource {
        FetchedSource(root: root, resolvedRef: "r2-test")
    }

    func invalidate(_ source: Source) {
        invalidations += 1
    }
}

struct R2InvariantTests {
    private let fm = FileManager.default

    private struct ManagedCase {
        let name: String
        let allowedOutside: Set<String>
        let setup: (ConfigDir) throws -> Void
        let run: (ConfigDir) throws -> Void
    }

    private func silent(_ message: String) {}

    private func makeConfig(initialized: Bool = true) throws -> ConfigDir {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-r2-\(UUID().uuidString)")
        let dir = ConfigDir(url: root)
        try fm.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try "outside sentinel\n".write(to: dir.url.appendingPathComponent("user.conf"), atomically: true, encoding: .utf8)
        try "font_size 12\n".write(to: dir.kittyConf, atomically: true, encoding: .utf8)
        if initialized {
            try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
            try ConfigStore.writeAtomically(Guard.insert(into: "font_size 12\n"), to: dir.kittyConf)
            try Data().write(to: dir.activeConf)
            try ConfigStore.writeMeta(Meta(createdConf: false, backup: nil), to: dir.metaFile)
            try SamplePlugins.seed(into: dir.pluginsDir)
        }
        return dir
    }

    private func seedProfile(_ dir: ConfigDir, name: String = "work", active: Bool = false) throws {
        let profile = try ProfileName(validating: name)
        let store = ProfileStore(root: dir.profilesDir)
        if !store.exists(profile) {
            let profileDir = try store.create(profile)
            try "font_size 13\n".write(to: profileDir.appendingPathComponent("base.conf"), atomically: true, encoding: .utf8)
        }
        if active {
            try ActivePointer(url: dir.activePointerFile).set(profile)
        }
    }

    private func seedTheme(_ dir: ConfigDir, name: String = "gruvbox", active: Bool = false) throws {
        let themesDir = dir.managedDir.appendingPathComponent("themes")
        try fm.createDirectory(at: themesDir, withIntermediateDirectories: true)
        try "background #282828\n".write(to: themesDir.appendingPathComponent("\(name).conf"), atomically: true, encoding: .utf8)
        if active {
            try "\(name)\n".write(to: dir.managedDir.appendingPathComponent(".kittymgr-theme"), atomically: true, encoding: .utf8)
        }
    }

    private func seedKey(_ dir: ConfigDir) throws {
        let keysDir = dir.managedDir.appendingPathComponent("keys")
        try fm.createDirectory(at: keysDir, withIntermediateDirectories: true)
        try "map ctrl+shift+e launch\n".write(to: keysDir.appendingPathComponent("ctrl-shift-e.conf"), atomically: true, encoding: .utf8)
    }

    private func seedSnippet(_ dir: ConfigDir) throws {
        let snippetsDir = dir.managedDir.appendingPathComponent("snippets")
        try fm.createDirectory(at: snippetsDir, withIntermediateDirectories: true)
        try "tab_bar_style powerline\n".write(to: snippetsDir.appendingPathComponent("tabs.conf"), atomically: true, encoding: .utf8)
    }

    private func seedKittenSource() throws -> URL {
        let source = fm.temporaryDirectory.appendingPathComponent("kittymgr-r2-kitten-\(UUID().uuidString)")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try "print('ok')\n".write(to: source.appendingPathComponent("main.py"), atomically: true, encoding: .utf8)
        return source
    }

    private func outsideManagedTree(_ dir: ConfigDir) throws -> [String: Data] {
        guard fm.fileExists(atPath: dir.url.path),
              let enumerator = fm.enumerator(at: dir.url, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [:] }

        let managedPath = dir.managedDir.standardizedFileURL.path
        var output: [String: Data] = [:]
        for case let url as URL in enumerator {
            if url.standardizedFileURL.path == managedPath {
                enumerator.skipDescendants()
                continue
            }
            var isDirectory: ObjCBool = false
            _ = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard !isDirectory.boolValue else { continue }
            output[dir.relativePath(of: url)] = try Data(contentsOf: url)
        }
        return output
    }

    private func changedPaths(from before: [String: Data], to after: [String: Data]) -> [String] {
        Set(before.keys).union(after.keys)
            .filter { before[$0] != after[$0] }
            .sorted()
    }

    private func assertOnlyOutsideChanges(
        _ allowed: Set<String>,
        around operation: () throws -> Void,
        in dir: ConfigDir,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let before = try outsideManagedTree(dir)
        try operation()
        let after = try outsideManagedTree(dir)
        let unexpected = changedPaths(from: before, to: after).filter { !allowed.contains($0) }
        #expect(unexpected.isEmpty, "unexpected outside changes: \(unexpected)", sourceLocation: sourceLocation)
    }

    private func blockCommand(_ action: BlockCommand.Action, dir: ConfigDir, dryRun: Bool = false) -> BlockCommand {
        BlockCommand(action: action, configDir: dir, dryRun: dryRun, validator: StubValidator(.valid), reloader: R2Reloader())
    }

    private func switchCommand(_ dir: ConfigDir, profile: String = "work", dryRun: Bool = false) -> SwitchCommand {
        SwitchCommand(
            profileStore: ProfileStore(root: dir.profilesDir),
            pluginStore: PluginStore(root: dir.pluginsDir),
            activePointer: ActivePointer(url: dir.activePointerFile),
            activeConf: dir.activeConf,
            rawName: profile,
            dryRun: dryRun,
            validator: StubValidator(.valid),
            reloader: R2Reloader()
        )
    }

    @Test func managedSurfaceCommandsDoNotMutateUserOwnedFiles() throws {
        let cases: [ManagedCase] = [
            ManagedCase(
                name: "init",
                allowedOutside: ["kitty.conf"],
                setup: { _ in },
                run: { dir in try InitCommand(configDir: dir).run(log: self.silent) }
            ),
            ManagedCase(
                name: "uninstall",
                allowedOutside: ["kitty.conf"],
                setup: { _ in },
                run: { dir in try UninstallCommand(configDir: dir).run(log: self.silent) }
            ),
            ManagedCase(
                name: "create",
                allowedOutside: [],
                setup: { _ in },
                run: { dir in try CreateCommand(store: ProfileStore(root: dir.profilesDir), rawName: "new-profile").run(log: self.silent) }
            ),
            ManagedCase(
                name: "delete",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir, name: "old") },
                run: { dir in try DeleteCommand(store: ProfileStore(root: dir.profilesDir), rawName: "old", force: true).run(log: self.silent) }
            ),
            ManagedCase(
                name: "switch",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir) },
                run: { dir in try self.switchCommand(dir).run(log: self.silent) }
            ),
            ManagedCase(
                name: "tui switch",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir) },
                run: { dir in
                    var keys: [TUIKey] = [.enter, .enter, .enter, .escape]
                    let engine = TUIEngine(
                        profileStore: ProfileStore(root: dir.profilesDir),
                        pluginStore: PluginStore(root: dir.pluginsDir),
                        activePointer: ActivePointer(url: dir.activePointerFile),
                        activeConf: dir.activeConf,
                        validator: StubValidator(.valid),
                        reloader: R2Reloader(),
                        terminal: ScriptedTerminal(),
                        readKey: { keys.isEmpty ? .escape : keys.removeFirst() },
                        write: { _ in }
                    )
                    try engine.start()
                }
            ),
            ManagedCase(
                name: "apply",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir, active: true) },
                run: { dir in try ApplyCommand(configDir: dir, validator: StubValidator(.valid), reloader: R2Reloader()).run(log: self.silent) }
            ),
            ManagedCase(
                name: "theme switch",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir, active: true); try self.seedTheme(dir) },
                run: { dir in try self.blockCommand(.themeSwitch(name: "gruvbox"), dir: dir).run(log: self.silent) }
            ),
            ManagedCase(
                name: "theme remove",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir, active: true); try self.seedTheme(dir, active: true) },
                run: { dir in try self.blockCommand(.themeRemove(name: "gruvbox"), dir: dir).run(log: self.silent) }
            ),
            ManagedCase(
                name: "key add",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir, active: true) },
                run: { dir in try self.blockCommand(.keyAdd(chord: "ctrl+shift+e", action: "launch"), dir: dir).run(log: self.silent) }
            ),
            ManagedCase(
                name: "key remove",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir, active: true); try self.seedKey(dir) },
                run: { dir in try self.blockCommand(.keyRemove(chord: "ctrl+shift+e"), dir: dir).run(log: self.silent) }
            ),
            ManagedCase(
                name: "snippet add",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir, active: true) },
                run: { dir in try self.blockCommand(.snippetAdd(name: "tabs", content: "tab_bar_style powerline\n"), dir: dir).run(log: self.silent) }
            ),
            ManagedCase(
                name: "snippet remove",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir, active: true); try self.seedSnippet(dir) },
                run: { dir in try self.blockCommand(.snippetRemove(name: "tabs"), dir: dir).run(log: self.silent) }
            ),
            ManagedCase(
                name: "plugin enable",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir, active: true) },
                run: { dir in
                    try PluginCommand(
                        action: .enable("theme-sample"),
                        profileStore: ProfileStore(root: dir.profilesDir),
                        pluginStore: PluginStore(root: dir.pluginsDir),
                        activePointer: ActivePointer(url: dir.activePointerFile),
                        activeConf: dir.activeConf,
                        reloader: R2Reloader()
                    ).run(log: self.silent)
                }
            ),
            ManagedCase(
                name: "plugin disable",
                allowedOutside: [],
                setup: { dir in
                    try self.seedProfile(dir, active: true)
                    try ProfileStore(root: dir.profilesDir).setMetadata(
                        ProfileMetadata(enabledPlugins: ["theme-sample"]),
                        for: try ProfileName(validating: "work")
                    )
                },
                run: { dir in
                    try PluginCommand(
                        action: .disable("theme-sample"),
                        profileStore: ProfileStore(root: dir.profilesDir),
                        pluginStore: PluginStore(root: dir.pluginsDir),
                        activePointer: ActivePointer(url: dir.activePointerFile),
                        activeConf: dir.activeConf,
                        reloader: R2Reloader()
                    ).run(log: self.silent)
                }
            ),
            ManagedCase(
                name: "kitten install",
                allowedOutside: [],
                setup: { _ in },
                run: { dir in
                    let source = try self.seedKittenSource()
                    try KittenCommand(action: .install(name: "tool", source: source.path), configDir: dir).run(log: self.silent)
                }
            ),
            ManagedCase(
                name: "kitten remove",
                allowedOutside: [],
                setup: { dir in
                    let source = try self.seedKittenSource()
                    try KittenCommand(action: .install(name: "tool", source: source.path), configDir: dir).run(log: self.silent)
                },
                run: { dir in try KittenCommand(action: .remove(name: "tool"), configDir: dir).run(log: self.silent) }
            ),
            ManagedCase(
                name: "backup create",
                allowedOutside: [],
                setup: { _ in },
                run: { dir in try BackupCommand(action: .create(label: "r2"), configDir: dir).run(log: self.silent) }
            ),
            ManagedCase(
                name: "clean",
                allowedOutside: [],
                setup: { dir in
                    let cache = dir.cacheDir.appendingPathComponent("orphan")
                    try self.fm.createDirectory(at: cache, withIntermediateDirectories: true)
                    try "cache\n".write(to: cache.appendingPathComponent("x"), atomically: true, encoding: .utf8)
                },
                run: { dir in try CleanCommand(configDir: dir).run(log: self.silent) }
            ),
            ManagedCase(
                name: "sync",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir); try self.writeSyncManifest(dir) },
                run: { dir in try Synchronizer(configDir: dir, validator: StubValidator(.valid), reloader: R2Reloader()).run(log: self.silent) }
            ),
            ManagedCase(
                name: "update",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir); try self.writeSyncManifest(dir, withSource: true) },
                run: { dir in
                    try UpdateCommand(
                        configDir: dir,
                        fetcher: R2Fetcher(root: dir.managedDir),
                        validator: StubValidator(.valid),
                        reloader: R2Reloader()
                    ).run(log: self.silent)
                }
            ),
        ]

        for testCase in cases {
            let dir = try makeConfig(initialized: testCase.name != "init")
            try testCase.setup(dir)
            try assertOnlyOutsideChanges(testCase.allowedOutside, around: {
                try testCase.run(dir)
            }, in: dir)
        }
    }

    @Test func dryRunCommandsLeaveDiskByteForByteUnchanged() throws {
        let dryRunCases: [ManagedCase] = [
            ManagedCase(
                name: "init",
                allowedOutside: [],
                setup: { _ in },
                run: { dir in try InitCommand(configDir: dir, dryRun: true).run(log: self.silent) }
            ),
            ManagedCase(
                name: "switch",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir) },
                run: { dir in try self.switchCommand(dir, dryRun: true).run(log: self.silent) }
            ),
            ManagedCase(
                name: "theme switch",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir, active: true); try self.seedTheme(dir) },
                run: { dir in try self.blockCommand(.themeSwitch(name: "gruvbox"), dir: dir, dryRun: true).run(log: self.silent) }
            ),
            ManagedCase(
                name: "plugin enable",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir, active: true) },
                run: { dir in
                    try PluginCommand(
                        action: .enable("theme-sample"),
                        profileStore: ProfileStore(root: dir.profilesDir),
                        pluginStore: PluginStore(root: dir.pluginsDir),
                        activePointer: ActivePointer(url: dir.activePointerFile),
                        activeConf: dir.activeConf,
                        dryRun: true,
                        validator: StubValidator(.valid),
                        reloader: R2Reloader()
                    ).run(log: self.silent)
                }
            ),
            ManagedCase(
                name: "key add",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir, active: true) },
                run: { dir in try self.blockCommand(.keyAdd(chord: "ctrl+shift+e", action: "launch"), dir: dir, dryRun: true).run(log: self.silent) }
            ),
            ManagedCase(
                name: "snippet add",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir, active: true) },
                run: { dir in try self.blockCommand(.snippetAdd(name: "tabs", content: "tab_bar_style powerline\n"), dir: dir, dryRun: true).run(log: self.silent) }
            ),
            ManagedCase(
                name: "kitten install",
                allowedOutside: [],
                setup: { _ in },
                run: { dir in
                    let source = try self.seedKittenSource()
                    try KittenCommand(action: .install(name: "tool", source: source.path), configDir: dir, dryRun: true).run(log: self.silent)
                }
            ),
            ManagedCase(
                name: "backup restore",
                allowedOutside: [],
                setup: { dir in
                    let snapshot = try SnapshotStore(configDir: dir).create(label: "base")
                    try "font_size 18\n".write(to: dir.activeConf, atomically: true, encoding: .utf8)
                    try snapshot.id.write(to: dir.managedDir.appendingPathComponent("restore-id"), atomically: true, encoding: .utf8)
                },
                run: { dir in
                    let id = try String(contentsOf: dir.managedDir.appendingPathComponent("restore-id"), encoding: .utf8)
                    try BackupCommand(action: .restore(id: id), configDir: dir, dryRun: true).run(log: self.silent)
                }
            ),
            ManagedCase(
                name: "sync",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir); try self.writeSyncManifest(dir) },
                run: { dir in try Synchronizer(configDir: dir, dryRun: true, validator: StubValidator(.valid), reloader: R2Reloader()).run(log: self.silent) }
            ),
            ManagedCase(
                name: "update",
                allowedOutside: [],
                setup: { dir in try self.seedProfile(dir); try self.writeSyncManifest(dir, withSource: true) },
                run: { dir in
                    try UpdateCommand(
                        configDir: dir,
                        dryRun: true,
                        fetcher: R2Fetcher(root: dir.managedDir),
                        validator: StubValidator(.valid),
                        reloader: R2Reloader()
                    ).run(log: self.silent)
                }
            ),
        ]

        for testCase in dryRunCases {
            let dir = try makeConfig(initialized: testCase.name != "init")
            try testCase.setup(dir)
            let beforeOutside = try outsideManagedTree(dir)
            let beforeManaged = try SnapshotStore(configDir: dir).currentSurface()
            try testCase.run(dir)
            #expect(try outsideManagedTree(dir) == beforeOutside, "\(testCase.name) changed user-owned files")
            #expect(try SnapshotStore(configDir: dir).currentSurface() == beforeManaged, "\(testCase.name) changed managed files")
        }
    }

    @Test func manifestAndSourceCommandsOnlyMutateRootManifest() throws {
        let manifestCases: [ManagedCase] = [
            ManagedCase(
                name: "manifest init",
                allowedOutside: ["kittymgr.toml"],
                setup: { dir in try self.seedProfile(dir, active: true) },
                run: { dir in try ManifestCommand(action: .initialize(force: false), configDir: dir).run(log: self.silent) }
            ),
            ManagedCase(
                name: "source add",
                allowedOutside: ["kittymgr.toml"],
                setup: { dir in try self.writeEmptyManifest(dir) },
                run: { dir in
                    try ManifestCommand(
                        action: .sourceAdd(SourceSpec(name: "themes", git: "https://example.invalid/themes")),
                        configDir: dir
                    ).run(log: self.silent)
                }
            ),
            ManagedCase(
                name: "source remove",
                allowedOutside: ["kittymgr.toml"],
                setup: { dir in
                    try Manifest(
                        sources: [SourceSpec(name: "themes", git: "https://example.invalid/themes")]
                    ).write(to: dir.manifestFile)
                },
                run: { dir in try ManifestCommand(action: .sourceRemove("themes"), configDir: dir).run(log: self.silent) }
            ),
        ]

        for testCase in manifestCases {
            let dir = try makeConfig()
            try testCase.setup(dir)
            try assertOnlyOutsideChanges(testCase.allowedOutside, around: {
                try testCase.run(dir)
            }, in: dir)
        }
    }

    @Test func backupRestoreReproducesSnapshotSurfaceAndLeavesUntrackedFilesAlone() throws {
        let dir = try makeConfig()
        let snapshot = try SnapshotStore(configDir: dir).create(label: "base")
        let expected = try SnapshotStore(configDir: dir).currentSurface()
        let untracked = dir.url.appendingPathComponent("not-in-snapshot.conf")
        try "external\n".write(to: untracked, atomically: true, encoding: .utf8)
        try "font_size 99\n".write(to: dir.kittyConf, atomically: true, encoding: .utf8)
        try "font_size 20\n".write(to: dir.activeConf, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: dir.profilesDir, withIntermediateDirectories: true)
        try "new\n".write(to: dir.profilesDir.appendingPathComponent("extra.conf"), atomically: true, encoding: .utf8)

        try BackupCommand(action: .restore(id: snapshot.id), configDir: dir).run(log: silent)

        #expect(try SnapshotStore(configDir: dir).currentSurface() == expected)
        #expect(try String(contentsOf: untracked, encoding: .utf8) == "external\n")
    }

    @Test func secondApplyEquivalentRunDoesNotCreateSnapshot() throws {
        let dir = try makeConfig()
        try seedProfile(dir, active: true)
        let command = ApplyCommand(configDir: dir, validator: StubValidator(.valid), reloader: R2Reloader())

        try command.run(log: silent)
        let snapshotsAfterFirst = SnapshotStore(configDir: dir).list().count
        try command.run(log: silent)

        #expect(SnapshotStore(configDir: dir).list().count == snapshotsAfterFirst)
    }

    private func writeEmptyManifest(_ dir: ConfigDir) throws {
        try Manifest().write(to: dir.manifestFile)
    }

    private func writeSyncManifest(_ dir: ConfigDir, withSource: Bool = false) throws {
        let sources = withSource
            ? [SourceSpec(name: "themes", git: "https://example.invalid/themes")]
            : []
        try Manifest(
            activeProfile: "work",
            profiles: [ProfileSpec(name: "work")],
            sources: sources
        ).write(to: dir.manifestFile)
    }
}
