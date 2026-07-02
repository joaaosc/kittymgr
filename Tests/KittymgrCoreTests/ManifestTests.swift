import Foundation
import Testing
@testable import KittymgrCore

struct TOMLLiteTests {
    @Test func classifiesTablesAndPairs() throws {
        #expect(try TOMLLite.classify("[settings]", number: 1) == .table("settings"))
        #expect(try TOMLLite.classify("[[sources]]", number: 1) == .arrayTable("sources"))
        #expect(try TOMLLite.classify("  # just a comment", number: 1) == nil)
        #expect(try TOMLLite.classify("", number: 1) == nil)
        #expect(try TOMLLite.classify("theme = \"gruvbox\"", number: 1) == .pair(key: "theme", value: .string("gruvbox")))
        #expect(try TOMLLite.classify("plugins = [\"a\", \"b\"]", number: 1) == .pair(key: "plugins", value: .array(["a", "b"])))
        #expect(try TOMLLite.classify("on = true", number: 1) == .pair(key: "on", value: .bool(true)))
        #expect(try TOMLLite.classify("schema_version = 2", number: 1) == .pair(key: "schema_version", value: .int(2)))
    }

    @Test func stripsCommentButNotInsideStrings() throws {
        #expect(try TOMLLite.classify("url = \"http://x#frag\"", number: 1)
            == .pair(key: "url", value: .string("http://x#frag")))
    }

    @Test func malformedValueThrowsWithLine() {
        #expect(throws: TOMLLite.ParseError.self) {
            _ = try TOMLLite.classify("k = nope", number: 7)
        }
    }
}

struct ManifestTests {
    private let fm = FileManager.default

    @Test func roundTripsParseAndSerialize() throws {
        let original = Manifest(
            activeProfile: "work",
            activeTheme: "gruvbox",
            profiles: [
                ProfileSpec(name: "work", description: "trabalho", plugins: ["tabs", "theme-sample"]),
                ProfileSpec(name: "focus", plugins: []),
            ],
            sources: [SourceSpec(name: "kitty-themes", git: "https://example/repo", ref: "master")]
        )
        let reparsed = try Manifest.parse(original.serialize())
        #expect(reparsed == original)
    }

    @Test func roundTripsSchemaV2WithArtifactsAndBlocks() throws {
        let original = Manifest(
            activeProfile: "work",
            activeTheme: "gruvbox",
            keys: ["ctrl-shift-e", "ctrl-shift-t"],
            snippets: ["scrollback"],
            profiles: [ProfileSpec(name: "work", plugins: ["tabs"])],
            sources: [SourceSpec(name: "themes", git: "https://example/themes")],
            themes: [InstallSpec(name: "gruvbox", from: "themes")],
            plugins: [InstallSpec(name: "tabs", from: "myplugins", ref: "v1")],
            kittens: [InstallSpec(name: "hints")]
        )
        let reparsed = try Manifest.parse(original.serialize())
        #expect(reparsed == original)
        #expect(reparsed.schemaVersion == Manifest.currentSchemaVersion)
    }

    @Test func migratesV1ManifestToV2WithoutDataLoss() throws {
        let v1 = """
        [settings]
        active_profile = "work"
        active_theme = "gruvbox"

        [profiles.work]
        plugins = ["tabs"]
        """
        let parsed = try Manifest.parse(v1)
        #expect(parsed.schemaVersion == 1)  // detected as pre-v2
        #expect(parsed.activeProfile == "work")
        #expect(parsed.profiles.first?.plugins == ["tabs"])
        #expect(parsed.themes.isEmpty)

        // Serializing migrates to v2 without losing the v1 data.
        let migrated = try Manifest.parse(parsed.serialize())
        #expect(migrated.schemaVersion == Manifest.currentSchemaVersion)
        #expect(migrated.activeProfile == "work")
        #expect(migrated.profiles.first?.plugins == ["tabs"])
    }

    @Test func parsesInstallTablesAndSlugBlocks() throws {
        let toml = """
        [settings]
        schema_version = 2
        active_profile = "work"
        keys = ["ctrl-shift-e"]
        snippets = ["scrollback"]

        [profiles.work]
        plugins = []

        [[themes]]
        name = "gruvbox"
        from = "kitty-themes"

        [[kittens]]
        name = "hints"
        from = "mykittens"
        ref = "main"
        """
        let manifest = try Manifest.parse(toml)
        #expect(manifest.schemaVersion == 2)
        #expect(manifest.keys == ["ctrl-shift-e"])
        #expect(manifest.snippets == ["scrollback"])
        #expect(manifest.themes == [InstallSpec(name: "gruvbox", from: "kitty-themes")])
        #expect(manifest.kittens == [InstallSpec(name: "hints", from: "mykittens", ref: "main")])
    }

    @Test func parseRejectsUnknownTable() {
        #expect(throws: TOMLLite.ParseError.self) {
            _ = try Manifest.parse("[bogus]\nx = \"y\"\n")
        }
    }

    @Test func parseRejectsPairOutsideTable() {
        #expect(throws: TOMLLite.ParseError.self) {
            _ = try Manifest.parse("active_profile = \"work\"\n")
        }
    }

    @Test func bootstrapReadsDiskState() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-manifest-\(UUID().uuidString)")
        let dir = ConfigDir(url: root)
        let store = ProfileStore(root: dir.profilesDir)
        _ = try store.create(try ProfileName(validating: "work"))
        try store.setMetadata(ProfileMetadata(enabledPlugins: ["tabs"]), for: try ProfileName(validating: "work"))
        try ActivePointer(url: dir.activePointerFile).set(try ProfileName(validating: "work"))

        let manifest = try Manifest.fromDisk(dir)
        #expect(manifest.activeProfile == "work")
        #expect(manifest.profiles.first(where: { $0.name == "work" })?.plugins == ["tabs"])
    }

    @Test func initWritesThenSourceAddUpdates() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-manifestcmd-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("managed"), withIntermediateDirectories: true)
        let dir = ConfigDir(url: root)
        _ = try ProfileStore(root: dir.profilesDir).create(try ProfileName(validating: "work"))

        try ManifestCommand(action: .initialize(force: false), configDir: dir).run(log: { _ in })
        #expect(fm.fileExists(atPath: dir.manifestFile.path))

        // init again without --force fails.
        #expect(throws: ManifestError.alreadyExists) {
            try ManifestCommand(action: .initialize(force: false), configDir: dir).run(log: { _ in })
        }

        try ManifestCommand(
            action: .sourceAdd(SourceSpec(name: "themes", git: "https://example/t", ref: "main")),
            configDir: dir
        ).run(log: { _ in })

        let reloaded = try Manifest.load(dir.manifestFile)
        #expect(reloaded?.sources.first?.name == "themes")
        #expect(reloaded?.sources.first?.source == Source(name: "themes", kind: .git(url: "https://example/t", ref: "main")))
    }
}
