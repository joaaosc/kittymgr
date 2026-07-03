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

    public enum AnchorState: Sendable, Equatable {
        case absent
        case current
        case legacy

        var hasBlock: Bool {
            switch self {
            case .current, .legacy: return true
            case .absent: return false
            }
        }
    }

    private struct ParsedLine {
        let number: Int
        let text: String
        let range: Range<String.Index>

        var normalizedText: String {
            text.hasSuffix("\r") ? String(text.dropLast()) : text
        }
    }

    private struct AnchorLocation {
        let state: AnchorState
        let blockRange: Range<String.Index>?
        let separatorRange: Range<String.Index>?
    }

    /// The exact text of the managed block, newline-terminated.
    public static func blockText() -> String {
        blockText(lineEnding: "\n")
    }

    public static func state(of content: String) throws -> AnchorState {
        try analyze(content).state
    }

    private static func blockText(lineEnding: String) -> String {
        [
            beginMarker,
            "# Managed by kittymgr. Do not edit inside these markers.",
            includeLine,
            endMarker,
        ].joined(separator: lineEnding) + lineEnding
    }

    /// Whether `content` already contains the managed block.
    public static func contains(in content: String) -> Bool {
        (try? state(of: content).hasBlock) ?? false
    }

    public static func containsCurrentInclude(in content: String) -> Bool {
        (try? state(of: content)) == .current
    }

    public static func containsLegacyInclude(in content: String) -> Bool {
        (try? state(of: content)) == .legacy
    }

    /// Insert the managed block at the top of `content`, leaving every existing
    /// line untouched (only shifted below the block). Idempotent: returns the
    /// input unchanged when the block is already present.
    public static func insert(into content: String) throws -> String {
        let location = try analyze(content)
        if location.state == .current {
            return content
        }
        if location.state == .legacy {
            throw corrupted("legacy include inside kittymgr block", line: markerLine(in: content, marker: legacyIncludeLine) ?? 1)
        }
        let block = blockText(lineEnding: newlineStyle(for: content))
        if content.isEmpty {
            return block
        }
        // One blank separator line keeps the managed block visually distinct.
        return block + newlineStyle(for: content) + content
    }

    /// Remove the managed block (and the separator line `insert` added),
    /// restoring the surrounding content exactly.
    public static func remove(from content: String) throws -> String {
        let location = try analyze(content)
        guard let blockRange = location.blockRange else {
            return content
        }
        let removalEnd = location.separatorRange?.upperBound ?? blockRange.upperBound
        return String(content[..<blockRange.lowerBound] + content[removalEnd...])
    }

    private static func analyze(_ content: String) throws -> AnchorLocation {
        let lines = parsedLines(in: content)
        let begins = lines.enumerated().filter { $0.element.normalizedText == beginMarker }
        let ends = lines.enumerated().filter { $0.element.normalizedText == endMarker }

        if begins.count > 1 {
            throw corrupted("multiple begin markers", line: begins[1].element.number)
        }
        if ends.count > 1 {
            throw corrupted("multiple end markers", line: ends[1].element.number)
        }
        if begins.isEmpty, let end = ends.first?.element {
            throw corrupted("end marker without begin marker", line: end.number)
        }
        if let begin = begins.first?.element, ends.isEmpty {
            throw corrupted("begin marker without end marker", line: begin.number)
        }
        guard let begin = begins.first, let end = ends.first else {
            return AnchorLocation(state: .absent, blockRange: nil, separatorRange: nil)
        }
        if end.offset < begin.offset {
            throw corrupted("end marker before begin marker", line: end.element.number)
        }

        let blockLines = lines[begin.offset...end.offset].map(\.normalizedText)
        let state: AnchorState
        if blockLines == expectedBlockLines(include: includeLine) {
            state = .current
        } else if blockLines == expectedBlockLines(include: legacyIncludeLine) {
            state = .legacy
        } else {
            throw corrupted("block contents drifted", line: begin.element.number)
        }

        let separator = lines.indices.contains(end.offset + 1) && lines[end.offset + 1].normalizedText.isEmpty
            ? lines[end.offset + 1].range
            : nil
        return AnchorLocation(state: state, blockRange: begin.element.range.lowerBound..<end.element.range.upperBound, separatorRange: separator)
    }

    private static func expectedBlockLines(include: String) -> [String] {
        [
            beginMarker,
            "# Managed by kittymgr. Do not edit inside these markers.",
            include,
            endMarker,
        ]
    }

    private static func parsedLines(in content: String) -> [ParsedLine] {
        var output: [ParsedLine] = []
        var start = content.startIndex
        var number = 1

        while start < content.endIndex {
            var bodyEnd = start
            while bodyEnd < content.endIndex, !content[bodyEnd].isNewline {
                bodyEnd = content.index(after: bodyEnd)
            }
            let lineEnd = bodyEnd < content.endIndex ? content.index(after: bodyEnd) : bodyEnd
            output.append(ParsedLine(number: number, text: String(content[start..<bodyEnd]), range: start..<lineEnd))
            start = lineEnd
            number += 1
        }
        return output
    }

    private static func newlineStyle(for content: String) -> String {
        content.contains("\r\n") ? "\r\n" : "\n"
    }

    private static func markerLine(in content: String, marker: String) -> Int? {
        parsedLines(in: content).first { $0.normalizedText == marker }?.number
    }

    private static func corrupted(_ detail: String, line: Int) -> SafetyError {
        SafetyError.corruptedAnchor(
            AnchorCorruption(
                detail: detail,
                line: line,
                repair: "Repair by removing the lines '\(beginMarker)' through '\(endMarker)', then run `kittymgr init`."
            )
        )
    }
}
