import Foundation

/// Resolves the active kitty configuration directory and exposes the well-known
/// paths that kittymgr operates on.
///
/// Resolution order mirrors kitty's own precedence:
/// 1. `KITTY_CONFIG_DIRECTORY`
/// 2. `$XDG_CONFIG_HOME/kitty`
/// 3. `~/.config/kitty`
///
/// On macOS kitty also recognizes `~/Library/Preferences/kitty`, but the modern
/// default is `~/.config/kitty`; the explicit `KITTY_CONFIG_DIRECTORY` override
/// covers the legacy location when a user relies on it.
public struct ConfigDir: Sendable, Equatable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ConfigDir {
        if let explicit = nonEmpty(environment["KITTY_CONFIG_DIRECTORY"]) {
            return ConfigDir(url: expand(explicit, home: home))
        }
        if let xdg = nonEmpty(environment["XDG_CONFIG_HOME"]) {
            return ConfigDir(url: expand(xdg, home: home).appendingPathComponent("kitty"))
        }
        return ConfigDir(url: home.appendingPathComponent(".config").appendingPathComponent("kitty"))
    }

    /// The user-owned entry point that receives the single guarded `include` block.
    public var kittyConf: URL { url.appendingPathComponent("kitty.conf") }

    /// Directory owned entirely by kittymgr.
    public var managedDir: URL { url.appendingPathComponent("kittymgr") }

    /// Legacy managed directory used by releases before the explicit owner layout.
    public var legacyManagedDir: URL { url.appendingPathComponent("managed") }

    /// Root holding one folder per named profile.
    public var profilesDir: URL { managedDir.appendingPathComponent("profiles") }

    /// Root holding one folder per available plugin.
    public var pluginsDir: URL { managedDir.appendingPathComponent("plugins") }

    /// Root holding one isolated folder per installed kitten (executable scripts).
    public var kittensDir: URL { managedDir.appendingPathComponent("kittens") }

    /// Cache of fetched remote sources (git checkouts, downloaded files).
    public var cacheDir: URL { managedDir.appendingPathComponent(".cache").appendingPathComponent("sources") }

    /// Root holding versioned snapshots of the managed surface.
    public var backupsDir: URL { managedDir.appendingPathComponent("backups") }

    /// Timestamped backups of the user-owned `kitty.conf`.
    public var confBackupsDir: URL { backupsDir.appendingPathComponent("conf") }

    /// Legacy location used while migrating `managed/` to `kittymgr/`.
    public var legacyConfBackupsDir: URL {
        legacyManagedDir.appendingPathComponent("backups").appendingPathComponent("conf")
    }

    /// Managed entry point referenced by the injected `include` line.
    public var activeConf: URL { managedDir.appendingPathComponent("active.conf") }

    /// User-facing declarative manifest (TOML-like v1).
    public var manifestFile: URL { url.appendingPathComponent("kittymgr.toml") }

    /// Machine-generated lockfile pinning resolved source versions.
    public var lockFile: URL { managedDir.appendingPathComponent("kittymgr.lock") }

    /// Legacy root-level lockfile used before generated state moved under `kittymgr/`.
    public var legacyLockFile: URL { url.appendingPathComponent("kittymgr.lock") }

    /// Authoritative pointer to the currently active profile.
    public var activePointerFile: URL { managedDir.appendingPathComponent(".kittymgr-active") }

    /// Sidecar state used to make `uninstall` an exact inverse of `init`.
    public var metaFile: URL { managedDir.appendingPathComponent(".kittymgr-meta") }

    /// Path of `url` relative to the config directory root, e.g.
    /// `kittymgr/active.conf`. Falls back to the last path component for URLs that
    /// do not live under the root.
    public func relativePath(of url: URL) -> String {
        let base = self.url.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(base + "/") {
            return String(path.dropFirst(base.count + 1))
        }
        return url.lastPathComponent
    }

    public func detectedLayout(fileManager fm: FileManager = .default) -> ConfigLayout {
        let hasNewDir = Self.isDirectory(managedDir, fileManager: fm)
        let hasLegacyDir = Self.isDirectory(legacyManagedDir, fileManager: fm)
        let hasNewPath = fm.fileExists(atPath: managedDir.path)
        let hasLegacyPath = fm.fileExists(atPath: legacyManagedDir.path)
        let hasRootLock = fm.fileExists(atPath: legacyLockFile.path)
        let hasNewLock = fm.fileExists(atPath: lockFile.path)
        let conf = try? String(contentsOf: kittyConf, encoding: .utf8)
        let hasCurrentAnchor = conf.map(Guard.containsCurrentInclude(in:)) ?? false
        let hasLegacyAnchor = conf.map(Guard.containsLegacyInclude(in:)) ?? false

        var mixedReasons: [String] = []
        if hasNewPath && !hasNewDir {
            mixedReasons.append("kittymgr exists but is not a directory")
        }
        if hasLegacyPath && !hasLegacyDir {
            mixedReasons.append("managed exists but is not a directory")
        }
        if hasNewDir && hasLegacyDir {
            mixedReasons.append("both kittymgr/ and managed/ exist")
        }
        if hasNewDir && hasRootLock {
            mixedReasons.append("legacy root lockfile exists")
        }
        if hasNewDir && hasLegacyAnchor {
            mixedReasons.append("kitty.conf still includes managed/active.conf")
        }
        if hasLegacyDir && hasCurrentAnchor {
            mixedReasons.append("legacy directory exists with kittymgr/ anchor")
        }
        if !hasNewDir && !hasLegacyDir && (hasRootLock || hasNewLock || hasCurrentAnchor || hasLegacyAnchor) {
            mixedReasons.append("layout files exist without an owner directory")
        }

        if !mixedReasons.isEmpty {
            return .mixed(mixedReasons.joined(separator: "; "))
        }
        if hasNewDir {
            return .current
        }
        if hasLegacyDir {
            return .legacy
        }
        return .absent
    }

    public func requireCurrentLayout(for command: String, fileManager: FileManager = .default) throws {
        let layout = detectedLayout(fileManager: fileManager)
        switch layout {
        case .legacy:
            throw ConfigLayoutError.legacy(command: command)
        case .mixed(let detail):
            throw ConfigLayoutError.mixed(detail)
        case .current, .absent:
            return
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func expand(_ path: String, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    private static func isDirectory(_ url: URL, fileManager fm: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

public enum ConfigLayout: Equatable, Sendable {
    case absent
    case current
    case legacy
    case mixed(String)

    public var label: String {
        switch self {
        case .absent: return "absent"
        case .current: return "new"
        case .legacy: return "legacy"
        case .mixed: return "mixed"
        }
    }
}

public enum ConfigLayoutError: Error, CustomStringConvertible, Equatable {
    case legacy(command: String)
    case mixed(String)
    case migrationFailed(String)

    public var description: String {
        switch self {
        case .legacy(let command):
            return "legacy layout detected for `kittymgr \(command)`: run `kittymgr init` to migrate managed/ to kittymgr/."
        case .mixed(let detail):
            return "mixed kittymgr layout detected (\(detail)). Repair the layout manually, then run `kittymgr init`."
        case .migrationFailed(let detail):
            return "migration failed: \(detail)"
        }
    }
}
