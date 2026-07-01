import Foundation

/// A single modular-block mutation. Each maps to a set of file writes/deletes plus
/// the resulting active block set, so it can flow through the transactional apply
/// path like any other change.
public enum BlockChange: Equatable {
    case installTheme(name: String, content: String)
    case switchTheme(name: String)
    case removeTheme(name: String)
    case addKey(slug: String, content: String)
    case removeKey(slug: String)
    case addSnippet(slug: String, content: String)
    case removeSnippet(slug: String)
}

/// The block half of a composed change: files to write/delete (paths relative to
/// the config directory) and the `include` lines + layers that the active blocks
/// contribute to `active.conf`.
struct BlockContribution {
    let writes: [String: String]
    let deletes: [String]
    let includes: [String]
    let layers: [ConfigLayer]
}

/// Resolves the current block set (optionally with a pending change applied) into a
/// `BlockContribution`. Pending writes are kept in an in-memory overlay so a
/// preview composes the post-change `active.conf` without touching disk.
enum BlockComposer {
    static func contribution(change: BlockChange?, blockStore: BlockStore) -> BlockContribution {
        var state = blockStore.state()
        var writes: [String: String] = [:]
        var deletes: [String] = []
        var overlay: [String: String] = [:]  // managed-relative path -> pending content

        let pointerPath = configPath(".kittymgr-theme")

        if let change {
            switch change {
            case let .installTheme(name, content):
                let managedRel = "themes/\(name).conf"
                writes[configPath(managedRel)] = content
                overlay[managedRel] = content

            case let .switchTheme(name):
                writes[pointerPath] = name + "\n"
                state.activeTheme = name

            case let .removeTheme(name):
                deletes.append(configPath("themes/\(name).conf"))
                if state.activeTheme == name {
                    deletes.append(pointerPath)
                    state.activeTheme = nil
                }

            case let .addKey(slug, content):
                let managedRel = "keys/\(slug).conf"
                writes[configPath(managedRel)] = content
                overlay[managedRel] = content
                if !state.keys.contains(slug) { state.keys.append(slug) }

            case let .removeKey(slug):
                deletes.append(configPath("keys/\(slug).conf"))
                state.keys.removeAll { $0 == slug }

            case let .addSnippet(slug, content):
                let managedRel = "snippets/\(slug).conf"
                writes[configPath(managedRel)] = content
                overlay[managedRel] = content
                if !state.snippets.contains(slug) { state.snippets.append(slug) }

            case let .removeSnippet(slug):
                deletes.append(configPath("snippets/\(slug).conf"))
                state.snippets.removeAll { $0 == slug }
            }
        }

        // Compose the active blocks in a deterministic order: theme, then snippets,
        // then keybindings (later includes win, but blocks rarely overlap).
        var includes: [String] = []
        var layers: [ConfigLayer] = []

        func add(_ managedRel: String) {
            includes.append(managedRel)
            let content = overlay[managedRel]
                ?? (try? String(contentsOf: blockStore.managedDir.appendingPathComponent(managedRel), encoding: .utf8))
                ?? ""
            layers.append(ConfigLayer(label: managedRel, content: content))
        }

        if let theme = state.activeTheme { add("themes/\(theme).conf") }
        for snippet in state.snippets.sorted() { add("snippets/\(snippet).conf") }
        for key in state.keys.sorted() { add("keys/\(key).conf") }

        return BlockContribution(writes: writes, deletes: deletes, includes: includes, layers: layers)
    }

    /// Map a managed-relative path to a config-directory-relative path.
    private static func configPath(_ managedRelative: String) -> String {
        "managed/" + managedRelative
    }
}
