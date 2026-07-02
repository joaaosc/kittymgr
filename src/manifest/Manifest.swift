import Foundation

/// One profile as described declaratively: which plugins it enables.
public struct ProfileSpec: Equatable, Sendable {
    public var name: String
    public var description: String?
    public var plugins: [String]

    public init(name: String, description: String? = nil, plugins: [String] = []) {
        self.name = name
        self.description = description
        self.plugins = plugins
    }
}

/// A named remote source the manifest can install from.
public struct SourceSpec: Equatable, Sendable {
    public var name: String
    public var git: String?
    public var url: String?
    public var ref: String?

    public init(name: String, git: String? = nil, url: String? = nil, ref: String? = nil) {
        self.name = name
        self.git = git
        self.url = url
        self.ref = ref
    }

    /// The `Source` this spec resolves to, if it names a location.
    public var source: Source? {
        if let git { return Source(name: name, kind: .git(url: git, ref: ref)) }
        if let url { return Source(name: name, kind: .url(url)) }
        return nil
    }
}

/// An artifact (theme, plugin, or kitten) installed from a named source: the
/// artifact `name`, the `from` source it comes from (a `[[sources]]` name), and an
/// optional `ref` override. `from == ""` means the origin is unknown — the artifact
/// is on disk but `sync` cannot reinstall it until a source is supplied.
public struct InstallSpec: Equatable, Sendable {
    public var name: String
    public var from: String
    public var ref: String?

    public init(name: String, from: String = "", ref: String? = nil) {
        self.name = name
        self.from = from
        self.ref = ref
    }
}

/// The declarative description of a kittymgr configuration, serialized as the
/// user-facing `kittymgr.toml`.
///
/// Schema v2 (an *extension* of v1) covers: the active selection
/// (`active_profile`, `active_theme`), each profile's enabled `plugins`, additive
/// `keys`/`snippets` (by slug — their content lives in `managed/keys|snippets/*.conf`,
/// versionable as dotfiles), named `[[sources]]`, and the installed artifacts
/// `[[themes]]`/`[[plugins]]`/`[[kittens]]` with their `from` source. A v1 manifest
/// (no `schema_version`, no artifact tables) still parses and is migrated to v2 on
/// the next write.
public struct Manifest: Equatable, Sendable {
    /// The schema version this build writes.
    public static let currentSchemaVersion = 2

    /// Schema version read from disk (1 when absent — a pre-v2 manifest).
    public var schemaVersion: Int
    public var activeProfile: String?
    public var activeTheme: String?
    public var keys: [String]
    public var snippets: [String]
    public var profiles: [ProfileSpec]
    public var sources: [SourceSpec]
    public var themes: [InstallSpec]
    public var plugins: [InstallSpec]
    public var kittens: [InstallSpec]

    public init(
        schemaVersion: Int = Manifest.currentSchemaVersion,
        activeProfile: String? = nil,
        activeTheme: String? = nil,
        keys: [String] = [],
        snippets: [String] = [],
        profiles: [ProfileSpec] = [],
        sources: [SourceSpec] = [],
        themes: [InstallSpec] = [],
        plugins: [InstallSpec] = [],
        kittens: [InstallSpec] = []
    ) {
        self.schemaVersion = schemaVersion
        self.activeProfile = activeProfile
        self.activeTheme = activeTheme
        self.keys = keys
        self.snippets = snippets
        self.profiles = profiles
        self.sources = sources
        self.themes = themes
        self.plugins = plugins
        self.kittens = kittens
    }

    // MARK: Bootstrap

    /// Build a manifest from the current on-disk state (for `manifest init`).
    ///
    /// Installed themes/plugins/kittens are listed with an empty `from` because
    /// their origin is not recorded on disk; `log` receives a note asking the user
    /// to fill each `from` so `sync` can reinstall them. `keys`/`snippets` are
    /// captured by slug (their content stays in `managed/keys|snippets/*.conf`).
    public static func fromDisk(_ configDir: ConfigDir, log: (String) -> Void = { _ in }) throws -> Manifest {
        let profileStore = ProfileStore(root: configDir.profilesDir)
        let blockStore = BlockStore(managedDir: configDir.managedDir)
        let pluginStore = PluginStore(root: configDir.pluginsDir)
        let kittenStore = KittenStore(root: configDir.kittensDir)
        let block = blockStore.state()

        let profiles = try profileStore.list().map { name -> ProfileSpec in
            let validated = try ProfileName(validating: name)
            return ProfileSpec(name: name, plugins: profileStore.metadata(for: validated).enabledPlugins)
        }
        let themes = blockStore.availableThemes().map { InstallSpec(name: $0) }
        let plugins = ((try? pluginStore.list()) ?? []).map { InstallSpec(name: $0.name) }
        let kittens = kittenStore.list().map { InstallSpec(name: $0.name) }

        if !themes.isEmpty || !plugins.isEmpty || !kittens.isEmpty {
            log("note: installed themes/plugins/kittens were written with an empty `from`; set each `from` to a `[[sources]]` name so `sync` can reinstall them.")
        }

        return Manifest(
            activeProfile: ActivePointer(url: configDir.activePointerFile).get(),
            activeTheme: block.activeTheme,
            keys: block.keys,
            snippets: block.snippets,
            profiles: profiles,
            sources: [],
            themes: themes,
            plugins: plugins,
            kittens: kittens
        )
    }

    // MARK: Parsing

    private enum ParseContext {
        case none, settings, profile(Int), source(Int), theme(Int), plugin(Int), kitten(Int)
    }

    public static func parse(_ text: String) throws -> Manifest {
        var manifest = Manifest()
        // Absent `schema_version` means a pre-v2 manifest; an explicit value overrides.
        manifest.schemaVersion = 1
        var context = ParseContext.none

        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let number = index + 1
            guard let line = try TOMLLite.classify(raw, number: number) else { continue }

            switch line {
            case let .table(name):
                if name == "settings" {
                    context = .settings
                } else if name.hasPrefix("profiles.") {
                    let profileName = String(name.dropFirst("profiles.".count))
                    manifest.profiles.append(ProfileSpec(name: profileName))
                    context = .profile(manifest.profiles.count - 1)
                } else {
                    throw TOMLLite.ParseError(line: number, message: "unknown table [\(name)]")
                }
            case let .arrayTable(name):
                switch name {
                case "sources":
                    manifest.sources.append(SourceSpec(name: ""))
                    context = .source(manifest.sources.count - 1)
                case "themes":
                    manifest.themes.append(InstallSpec(name: ""))
                    context = .theme(manifest.themes.count - 1)
                case "plugins":
                    manifest.plugins.append(InstallSpec(name: ""))
                    context = .plugin(manifest.plugins.count - 1)
                case "kittens":
                    manifest.kittens.append(InstallSpec(name: ""))
                    context = .kitten(manifest.kittens.count - 1)
                default:
                    throw TOMLLite.ParseError(line: number, message: "unknown array-of-tables [[\(name)]]")
                }
            case let .pair(key, value):
                try assign(key: key, value: value, context: context, into: &manifest, line: number)
            }
        }
        return manifest
    }

    private static func assign(
        key: String,
        value: TOMLLite.Value,
        context: ParseContext,
        into manifest: inout Manifest,
        line: Int
    ) throws {
        func str() throws -> String {
            guard case let .string(s) = value else { throw TOMLLite.ParseError(line: line, message: "'\(key)' expects a string") }
            return s
        }
        func arr() throws -> [String] {
            guard case let .array(a) = value else { throw TOMLLite.ParseError(line: line, message: "'\(key)' expects an array") }
            return a
        }
        func int() throws -> Int {
            guard case let .int(i) = value else { throw TOMLLite.ParseError(line: line, message: "'\(key)' expects an integer") }
            return i
        }

        switch context {
        case .settings:
            switch key {
            case "schema_version": manifest.schemaVersion = try int()
            case "active_profile": manifest.activeProfile = try str()
            case "active_theme": manifest.activeTheme = try str()
            case "keys": manifest.keys = try arr()
            case "snippets": manifest.snippets = try arr()
            default: throw TOMLLite.ParseError(line: line, message: "unknown setting '\(key)'")
            }
        case let .profile(i):
            switch key {
            case "plugins": manifest.profiles[i].plugins = try arr()
            case "description": manifest.profiles[i].description = try str()
            default: throw TOMLLite.ParseError(line: line, message: "unknown profile key '\(key)'")
            }
        case let .source(i):
            switch key {
            case "name": manifest.sources[i].name = try str()
            case "git": manifest.sources[i].git = try str()
            case "url": manifest.sources[i].url = try str()
            case "ref": manifest.sources[i].ref = try str()
            default: throw TOMLLite.ParseError(line: line, message: "unknown source key '\(key)'")
            }
        case let .theme(i):
            try assignInstall(&manifest.themes[i], key: key, string: try str(), line: line)
        case let .plugin(i):
            try assignInstall(&manifest.plugins[i], key: key, string: try str(), line: line)
        case let .kitten(i):
            try assignInstall(&manifest.kittens[i], key: key, string: try str(), line: line)
        case .none:
            throw TOMLLite.ParseError(line: line, message: "'\(key)' outside any table")
        }
    }

    private static func assignInstall(_ spec: inout InstallSpec, key: String, string: String, line: Int) throws {
        switch key {
        case "name": spec.name = string
        case "from": spec.from = string
        case "ref": spec.ref = string
        default: throw TOMLLite.ParseError(line: line, message: "unknown install key '\(key)'")
        }
    }

    // MARK: Serializing

    public func serialize() -> String {
        var lines = ["# kittymgr manifest (TOML-like v\(Manifest.currentSchemaVersion)). Managed declaratively; edit and run `kittymgr sync`."]

        lines.append("")
        lines.append("[settings]")
        lines.append("schema_version = \(Manifest.currentSchemaVersion)")
        if let activeProfile { lines.append("active_profile = \(TOMLLite.string(activeProfile))") }
        if let activeTheme { lines.append("active_theme = \(TOMLLite.string(activeTheme))") }
        if !keys.isEmpty { lines.append("keys = \(TOMLLite.array(keys))") }
        if !snippets.isEmpty { lines.append("snippets = \(TOMLLite.array(snippets))") }

        for profile in profiles {
            lines.append("")
            lines.append("[profiles.\(profile.name)]")
            if let description = profile.description { lines.append("description = \(TOMLLite.string(description))") }
            lines.append("plugins = \(TOMLLite.array(profile.plugins))")
        }

        for source in sources {
            lines.append("")
            lines.append("[[sources]]")
            lines.append("name = \(TOMLLite.string(source.name))")
            if let git = source.git { lines.append("git = \(TOMLLite.string(git))") }
            if let url = source.url { lines.append("url = \(TOMLLite.string(url))") }
            if let ref = source.ref { lines.append("ref = \(TOMLLite.string(ref))") }
        }

        appendInstalls(&lines, table: "themes", specs: themes)
        appendInstalls(&lines, table: "plugins", specs: plugins)
        appendInstalls(&lines, table: "kittens", specs: kittens)

        return lines.joined(separator: "\n") + "\n"
    }

    private func appendInstalls(_ lines: inout [String], table: String, specs: [InstallSpec]) {
        for spec in specs {
            lines.append("")
            lines.append("[[\(table)]]")
            lines.append("name = \(TOMLLite.string(spec.name))")
            lines.append("from = \(TOMLLite.string(spec.from))")
            if let ref = spec.ref { lines.append("ref = \(TOMLLite.string(ref))") }
        }
    }

    // MARK: Disk

    public static func load(_ url: URL) throws -> Manifest? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try parse(text)
    }

    public func write(to url: URL) throws {
        try serialize().write(to: url, atomically: true, encoding: .utf8)
    }
}
