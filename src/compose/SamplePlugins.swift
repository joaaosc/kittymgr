import Foundation

/// A plugin bundled with kittymgr, seeded into `managed/plugins/` so the plugin
/// workflow is usable out of the box.
struct SamplePlugin {
    let name: String
    let priority: Int
    /// File name -> contents for each `.conf` snippet.
    let files: [String: String]
}

enum SamplePlugins {
    /// One sample theme plugin used for validation and as a starting point.
    static let all: [SamplePlugin] = [
        SamplePlugin(
            name: "theme-sample",
            priority: 50,
            files: [
                "theme.conf": """
                # Sample theme bundled with kittymgr.
                background #1d2021
                foreground #ebdbb2
                cursor #ebdbb2
                selection_background #504945

                """,
            ]
        ),
    ]

    /// Write bundled samples into `pluginsRoot`, skipping any plugin that already
    /// exists so user edits are never overwritten.
    static func seed(into pluginsRoot: URL, fileManager: FileManager = .default) throws {
        for plugin in all {
            let directory = pluginsRoot.appendingPathComponent(plugin.name, isDirectory: true)
            guard !fileManager.fileExists(atPath: directory.path) else { continue }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for (file, contents) in plugin.files {
                try contents.write(to: directory.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
            let meta = "priority=\(plugin.priority)\n"
            try meta.write(to: directory.appendingPathComponent("plugin.meta"), atomically: true, encoding: .utf8)
        }
    }
}
