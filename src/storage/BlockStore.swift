import Foundation

/// The active set of modular blocks: the single active theme (mutually exclusive)
/// plus the additive sets of keybinding and snippet slugs.
public struct BlockState: Equatable, Sendable {
    public var activeTheme: String?
    public var keys: [String]
    public var snippets: [String]

    public init(activeTheme: String? = nil, keys: [String] = [], snippets: [String] = []) {
        self.activeTheme = activeTheme
        self.keys = keys
        self.snippets = snippets
    }
}

/// Enumerates the modular blocks that layer on top of any profile:
///
/// - `kittymgr/themes/<name>.conf` — installed themes; one is active at a time,
///   recorded in `kittymgr/.kittymgr-theme`.
/// - `kittymgr/keys/<slug>.conf` — keybinding includes (additive: all present are
///   active).
/// - `kittymgr/snippets/<slug>.conf` — snippet includes (additive).
///
/// Read-only over the filesystem; mutations are expressed as `ApplyPlan` writes and
/// deletes so they flow through the transactional apply path.
public struct BlockStore {
    public let managedDir: URL
    private let fileManager: FileManager

    public init(managedDir: URL, fileManager: FileManager = .default) {
        self.managedDir = managedDir
        self.fileManager = fileManager
    }

    public var themesDir: URL { managedDir.appendingPathComponent("themes") }
    public var keysDir: URL { managedDir.appendingPathComponent("keys") }
    public var snippetsDir: URL { managedDir.appendingPathComponent("snippets") }
    public var activeThemeFile: URL { managedDir.appendingPathComponent(".kittymgr-theme") }

    /// The currently active blocks, read from disk.
    public func state() -> BlockState {
        BlockState(
            activeTheme: activeTheme(),
            keys: slugs(in: keysDir),
            snippets: slugs(in: snippetsDir)
        )
    }

    public func availableThemes() -> [String] { slugs(in: themesDir) }

    public func themeExists(_ name: String) -> Bool {
        fileManager.fileExists(atPath: themesDir.appendingPathComponent(name + ".conf").path)
    }

    private func activeTheme() -> String? {
        guard let text = try? String(contentsOf: activeThemeFile, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The `.conf` basenames (without extension) in `directory`, lexically sorted.
    private func slugs(in directory: URL) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "conf" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }
}
