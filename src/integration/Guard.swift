import Foundation

/// Detects, inserts, and removes the single guarded `include` block that kittymgr
/// owns inside the user's `kitty.conf`.
///
/// The block is inserted at the TOP of `kitty.conf` so the managed `include` is
/// evaluated before the user's own settings. kitty applies options last-wins, so
/// this gives the user's `kitty.conf` final precedence over managed layers.
///
/// All operations are pure string transformations so they can be unit tested in
/// isolation and so the insert/remove pair stays exactly reversible: user content
/// is never modified, only shifted below the block.
public enum Guard {
    public static let beginMarker = "# >>> kittymgr (managed) >>>"
    public static let endMarker = "# <<< kittymgr (managed) <<<"
    public static let includeLine = "include kittymgr/active.conf"
    public static let legacyIncludeLine = "include managed/active.conf"

    /// The exact text of the managed block, newline-terminated.
    public static func blockText() -> String {
        [
            beginMarker,
            "# Managed by kittymgr. Do not edit inside these markers.",
            includeLine,
            endMarker,
        ].joined(separator: "\n") + "\n"
    }

    /// Whether `content` already contains the managed block.
    public static func contains(in content: String) -> Bool {
        let lines = content.components(separatedBy: "\n")
        return lines.contains(beginMarker) && lines.contains(endMarker)
    }

    public static func containsCurrentInclude(in content: String) -> Bool {
        let lines = content.components(separatedBy: "\n")
        return contains(in: content) && lines.contains(includeLine)
    }

    public static func containsLegacyInclude(in content: String) -> Bool {
        let lines = content.components(separatedBy: "\n")
        return contains(in: content) && lines.contains(legacyIncludeLine)
    }

    /// Insert the managed block at the top of `content`, leaving every existing
    /// line untouched (only shifted below the block). Idempotent: returns the
    /// input unchanged when the block is already present.
    public static func insert(into content: String) -> String {
        if contains(in: content) {
            return content
        }
        let block = blockText()
        if content.isEmpty {
            return block
        }
        // One blank separator line keeps the managed block visually distinct.
        return block + "\n" + content
    }

    /// Remove the managed block (and the separator line `insert` added),
    /// restoring the surrounding content exactly.
    public static func remove(from content: String) -> String {
        var lines = content.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(of: beginMarker),
              let end = lines[begin...].firstIndex(of: endMarker),
              end >= begin
        else {
            return content
        }
        lines.removeSubrange(begin...end)
        // Drop the single blank separator line that followed the block.
        if begin < lines.count, lines[begin].isEmpty {
            lines.remove(at: begin)
        }
        return lines.joined(separator: "\n")
    }
}
