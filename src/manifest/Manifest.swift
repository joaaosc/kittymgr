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

/// The declarative description of a kittymgr configuration: the active selection,
/// each profile's enabled plugins, and the remote sources. Serialized as the
/// user-facing `kittymgr.toml` (TOML-like v1).
///
/// Scope of v1: the reproducible *state* — `active_profile`, `active_theme`, and
/// per-profile enabled `plugins` — plus named `sources`. Block content
/// (keys/snippets) stays imperative for now (see README).
public struct Manifest: Equatable, Sendable {
    public var activeProfile: String?
    public var activeTheme: String?
    public var profiles: [ProfileSpec]
    public var sources: [SourceSpec]

    public init(
        activeProfile: String? = nil,
        activeTheme: String? = nil,
        profiles: [ProfileSpec] = [],
        sources: [SourceSpec] = []
    ) {
        self.activeProfile = activeProfile
        self.activeTheme = activeTheme
        self.profiles = profiles
        self.sources = sources
    }

    // MARK: Bootstrap

    /// Build a manifest from the current on-disk state (for `manifest init`).
    public static func fromDisk(_ configDir: ConfigDir) throws -> Manifest {
        let profileStore = ProfileStore(root: configDir.profilesDir)
        let profiles = try profileStore.list().map { name -> ProfileSpec in
            let validated = try ProfileName(validating: name)
            return ProfileSpec(name: name, plugins: profileStore.metadata(for: validated).enabledPlugins)
        }
        return Manifest(
            activeProfile: ActivePointer(url: configDir.activePointerFile).get(),
            activeTheme: BlockStore(managedDir: configDir.managedDir).state().activeTheme,
            profiles: profiles,
            sources: []
        )
    }

    // MARK: Parsing

    private enum ParseContext {
        case none, settings, profile(Int), source(Int)
    }

    public static func parse(_ text: String) throws -> Manifest {
        var manifest = Manifest()
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
                guard name == "sources" else {
                    throw TOMLLite.ParseError(line: number, message: "unknown array-of-tables [[\(name)]]")
                }
                manifest.sources.append(SourceSpec(name: ""))
                context = .source(manifest.sources.count - 1)
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

        switch context {
        case .settings:
            switch key {
            case "active_profile": manifest.activeProfile = try str()
            case "active_theme": manifest.activeTheme = try str()
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
        case .none:
            throw TOMLLite.ParseError(line: line, message: "'\(key)' outside any table")
        }
    }

    // MARK: Serializing

    public func serialize() -> String {
        var lines = ["# kittymgr manifest (TOML-like v1). Managed declaratively; edit and run `kittymgr sync`."]

        if activeProfile != nil || activeTheme != nil {
            lines.append("")
            lines.append("[settings]")
            if let activeProfile { lines.append("active_profile = \(TOMLLite.string(activeProfile))") }
            if let activeTheme { lines.append("active_theme = \(TOMLLite.string(activeTheme))") }
        }

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

        return lines.joined(separator: "\n") + "\n"
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
