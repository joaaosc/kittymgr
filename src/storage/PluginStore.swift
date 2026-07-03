import Foundation

/// Enumerates available plugins under `kittymgr/plugins/` and reads their snippets
/// and optional metadata. Read-only: plugins are authored on disk or seeded as
/// samples; this store never mutates them.
public struct PluginStore {
    public let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    public func directory(for name: PluginName) -> URL {
        root.appendingPathComponent(name.value, isDirectory: true)
    }

    /// All available plugins in deterministic order (priority, then name).
    public func list() throws -> [Plugin] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let plugins = entries.compactMap { url -> Plugin? in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { return nil }
            let name = url.lastPathComponent
            return Plugin(name: name, priority: priority(of: name))
        }
        return plugins.sorted(by: Plugin.order)
    }

    public func exists(_ name: PluginName) -> Bool {
        var isDirectory: ObjCBool = false
        let present = fileManager.fileExists(atPath: directory(for: name).path, isDirectory: &isDirectory)
        return present && isDirectory.boolValue
    }

    /// The `.conf` files in a plugin, lexically sorted for reproducible ordering.
    public func confFiles(in name: String) throws -> [String] {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let confs = entries.filter { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return !isDirectory && url.pathExtension == "conf"
        }
        return confs.map(\.lastPathComponent).sorted()
    }

    /// Reads `priority=<int>` from the plugin's optional `plugin.meta`; defaults to 0.
    public func priority(of name: String) -> Int {
        let metaURL = root.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("plugin.meta")
        guard let text = try? String(contentsOf: metaURL, encoding: .utf8) else { return 0 }
        for line in text.components(separatedBy: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "priority", let value = Int(parts[1]) {
                return value
            }
        }
        return 0
    }
}
