import Foundation

/// Detects, inserts, and removes the single guarded `include` block that kittymgr
/// owns inside the user's `kitty.conf`.
///
/// All operations are pure string transformations so they can be unit tested in
/// isolation and so the insert/remove pair stays exactly reversible.
public enum Guard {
    public static let beginMarker = "# >>> kittymgr (managed) >>>"
    public static let endMarker = "# <<< kittymgr (managed) <<<"
    public static let includeLine = "include managed/active.conf"

    /// Result of appending the managed block, carrying the information needed to
    /// invert the change byte-for-byte during `uninstall`.
    public struct AppendResult: Sendable, Equatable {
        public let content: String
        /// Whether a terminating newline was added to previously unterminated
        /// user content. `uninstall` strips it back to restore the original.
        public let addedTrailingNewline: Bool
    }

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

    /// Append the managed block to `content`, leaving every existing line untouched.
    /// Idempotent: returns the input unchanged when the block is already present.
    public static func append(to content: String) -> AppendResult {
        if contains(in: content) {
            return AppendResult(content: content, addedTrailingNewline: false)
        }
        let block = blockText()
        if content.isEmpty {
            return AppendResult(content: block, addedTrailingNewline: false)
        }
        var body = content
        var addedTrailingNewline = false
        if !body.hasSuffix("\n") {
            body += "\n"
            addedTrailingNewline = true
        }
        // One blank separator line keeps the managed block visually distinct.
        return AppendResult(content: body + "\n" + block, addedTrailingNewline: addedTrailingNewline)
    }

    /// Remove the managed block (and the separator line `append` inserted),
    /// restoring the surrounding content exactly.
    public static func remove(from content: String, addedTrailingNewline: Bool = false) -> String {
        var lines = content.components(separatedBy: "\n")
        guard let begin = lines.firstIndex(of: beginMarker),
              let end = lines[begin...].firstIndex(of: endMarker),
              end >= begin
        else {
            return content
        }
        lines.removeSubrange(begin...end)
        // Drop the single blank separator line inserted ahead of the block.
        if begin > 0, begin - 1 < lines.count, lines[begin - 1].isEmpty {
            lines.remove(at: begin - 1)
        }
        var result = lines.joined(separator: "\n")
        if addedTrailingNewline, result.hasSuffix("\n") {
            result.removeLast()
        }
        return result
    }
}
