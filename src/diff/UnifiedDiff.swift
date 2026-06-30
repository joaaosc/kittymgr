import Foundation

/// Minimal, dependency-free unified-diff generator.
///
/// Uses a Longest-Common-Subsequence edit script so the output matches what
/// standard tooling (and humans) expect for previews and `--dry-run`. Lines are
/// compared with a single trailing newline treated as the line terminator, which
/// is the common case for kitty config files.
public enum UnifiedDiff {
    private enum Edit {
        case equal(String)
        case delete(String)
        case insert(String)

        var isChange: Bool {
            if case .equal = self { return false }
            return true
        }

        var isInsert: Bool {
            if case .insert = self { return true }
            return false
        }

        var isDelete: Bool {
            if case .delete = self { return true }
            return false
        }
    }

    /// Unified diff between two file contents. Returns `""` when identical.
    public static func diff(
        old: String,
        new: String,
        oldLabel: String,
        newLabel: String,
        context: Int = 3
    ) -> String {
        if old == new { return "" }
        let edits = lcs(splitLines(old), splitLines(new))
        let hunks = group(edits, context: context)
        guard !hunks.isEmpty else { return "" }

        var out = "--- \(oldLabel)\n+++ \(newLabel)\n"
        out += hunks.map(render).joined()
        return out
    }

    /// Combined diff over two keyed states (relative path -> contents), covering
    /// added, removed, and modified files. Empty when the states match.
    public static func diffStates(old: [String: String], new: [String: String]) -> String {
        let paths = Set(old.keys).union(new.keys).sorted()
        var out = ""
        for path in paths {
            let before = old[path]
            let after = new[path]
            guard before != after else { continue }
            out += diff(
                old: before ?? "",
                new: after ?? "",
                oldLabel: before == nil ? "/dev/null" : "a/\(path)",
                newLabel: after == nil ? "/dev/null" : "b/\(path)"
            )
        }
        return out
    }

    // MARK: Line model

    /// Split into lines, treating a single trailing newline as the terminator so
    /// newline-ended files do not produce a spurious empty final line.
    private static func splitLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: LCS edit script

    private static func lcs(_ a: [String], _ b: [String]) -> [Edit] {
        let n = a.count
        let m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var edits: [Edit] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                edits.append(.equal(a[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                edits.append(.delete(a[i])); i += 1
            } else {
                edits.append(.insert(b[j])); j += 1
            }
        }
        while i < n { edits.append(.delete(a[i])); i += 1 }
        while j < m { edits.append(.insert(b[j])); j += 1 }
        return edits
    }

    // MARK: Hunking

    private struct Tagged {
        let edit: Edit
        let oldLine: Int
        let newLine: Int
    }

    private static func group(_ edits: [Edit], context: Int) -> [[Tagged]] {
        var tagged: [Tagged] = []
        var oldLine = 1
        var newLine = 1
        for edit in edits {
            tagged.append(Tagged(edit: edit, oldLine: oldLine, newLine: newLine))
            switch edit {
            case .equal: oldLine += 1; newLine += 1
            case .delete: oldLine += 1
            case .insert: newLine += 1
            }
        }

        var hunks: [[Tagged]] = []
        var i = 0
        let count = tagged.count
        while i < count {
            guard tagged[i].edit.isChange else { i += 1; continue }

            var end = i
            var j = i
            while j < count {
                if tagged[j].edit.isChange {
                    end = j
                    j += 1
                } else {
                    var k = j
                    while k < count && !tagged[k].edit.isChange { k += 1 }
                    // Merge changes separated by a short equal run into one hunk.
                    if k < count && (k - j) <= 2 * context {
                        j = k
                    } else {
                        break
                    }
                }
            }

            let lo = max(i - context, 0)
            let hi = min(end + context, count - 1)
            hunks.append(Array(tagged[lo...hi]))
            i = hi + 1
        }
        return hunks
    }

    private static func render(_ hunk: [Tagged]) -> String {
        let oldLines = hunk.compactMap { tag -> Int? in
            tag.edit.isInsert ? nil : tag.oldLine
        }
        let newLines = hunk.compactMap { tag -> Int? in
            tag.edit.isDelete ? nil : tag.newLine
        }
        let oldStart = oldLines.first ?? hunk.first?.oldLine ?? 0
        let newStart = newLines.first ?? hunk.first?.newLine ?? 0

        var out = "@@ -\(oldStart),\(oldLines.count) +\(newStart),\(newLines.count) @@\n"
        for tag in hunk {
            switch tag.edit {
            case .equal(let line): out += " \(line)\n"
            case .delete(let line): out += "-\(line)\n"
            case .insert(let line): out += "+\(line)\n"
            }
        }
        return out
    }
}
