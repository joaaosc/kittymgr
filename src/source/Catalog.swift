import Foundation

/// Locates and lists themes inside a fetched source tree.
///
/// A theme catalog (like the `kitty-themes` repository) keeps one `.conf` per theme
/// under `themes/`; a plain git source may keep them at the root. Names are matched
/// loosely (case-insensitive, ignoring spaces/`_`/`-`): an exact normalized match
/// wins, otherwise a unique substring match (so `gruvbox` finds `Gruvbox_Dark.conf`
/// when it is the only candidate).
enum Catalog {
    static func findTheme(named name: String, in root: URL) -> URL? {
        let target = normalize(name)
        let entries = themeFiles(in: root)
        if let exact = entries.first(where: { normalize(baseName($0)) == target }) {
            return exact
        }
        let contains = entries.filter { normalize(baseName($0)).contains(target) }
        return contains.count == 1 ? contains.first : nil
    }

    static func listThemes(in root: URL) -> [String] {
        themeFiles(in: root).map(baseName).sorted()
    }

    /// The `.conf` files from `themes/` if it has any, otherwise from the root.
    private static func themeFiles(in root: URL) -> [URL] {
        let themed = confFiles(in: root.appendingPathComponent("themes"))
        return themed.isEmpty ? confFiles(in: root) : themed
    }

    private static func confFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "conf" } ?? []
    }

    private static func baseName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}
