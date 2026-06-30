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
    public var managedDir: URL { url.appendingPathComponent("managed") }

    /// Managed entry point referenced by the injected `include` line.
    public var activeConf: URL { managedDir.appendingPathComponent("active.conf") }

    /// Sidecar state used to make `uninstall` an exact inverse of `init`.
    public var metaFile: URL { managedDir.appendingPathComponent(".kittymgr-meta") }

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
}
