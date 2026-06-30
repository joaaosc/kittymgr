import Foundation

/// Builds the ordered list of `include` paths that compose into `active.conf`.
///
/// Layering (each layer overrides the previous, since kitty is last-wins):
///   1. profile base snippets — `profiles/<profile>/*.conf` (lexical)
///   2. enabled plugins — `plugins/<plugin>/*.conf`, plugins ordered by
///      (priority ascending, then name); higher priority wins
///
/// The user's own `kitty.conf` settings sit after the whole managed `include`
/// (the guard block is at the top of `kitty.conf`), so they retain final
/// precedence over every managed layer.
enum IncludeBuilder {
    /// Paths are relative to the managed directory, where `active.conf` lives.
    static func includes(
        profile: ProfileName,
        profileStore: ProfileStore,
        pluginStore: PluginStore,
        enabledPlugins: [String]
    ) throws -> [String] {
        var includes: [String] = []

        for file in try profileStore.confFiles(in: profile) {
            includes.append("profiles/\(profile.value)/\(file)")
        }

        let enabled = Set(enabledPlugins)
        let orderedPlugins = try pluginStore.list().filter { enabled.contains($0.name) }
        for plugin in orderedPlugins {
            for file in try pluginStore.confFiles(in: plugin.name) {
                includes.append("plugins/\(plugin.name)/\(file)")
            }
        }

        return includes
    }

    /// The ordered source layers (one per `.conf` file) that compose into the
    /// active configuration, with their contents — used for conflict detection
    /// and validation. Same order as `includes`.
    static func layers(
        profile: ProfileName,
        profileStore: ProfileStore,
        pluginStore: PluginStore,
        enabledPlugins: [String]
    ) throws -> [ConfigLayer] {
        var layers: [ConfigLayer] = []

        let profileDir = profileStore.directory(for: profile)
        for file in try profileStore.confFiles(in: profile) {
            let url = profileDir.appendingPathComponent(file)
            let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            layers.append(ConfigLayer(label: "profiles/\(profile.value)/\(file)", content: content))
        }

        let enabled = Set(enabledPlugins)
        for plugin in try pluginStore.list().filter({ enabled.contains($0.name) }) {
            for file in try pluginStore.confFiles(in: plugin.name) {
                let url = pluginStore.root.appendingPathComponent(plugin.name).appendingPathComponent(file)
                let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                layers.append(ConfigLayer(label: "plugins/\(plugin.name)/\(file)", content: content))
            }
        }

        return layers
    }

    /// Inline the layers into a single composed document for parser validation.
    static func compose(_ layers: [ConfigLayer]) -> String {
        guard !layers.isEmpty else { return "" }
        return layers.map { "# >>> \($0.label)\n\($0.content)" }.joined(separator: "\n") + "\n"
    }
}
