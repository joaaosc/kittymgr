import Foundation
import Testing
@testable import KittymgrCore

struct GuardTests {
    @Test func blockContainsSingleIncludeBetweenMarkers() {
        let block = Guard.blockText()
        #expect(block.contains(Guard.beginMarker))
        #expect(block.contains(Guard.endMarker))
        let includeCount = block.components(separatedBy: "\n").filter { $0 == Guard.includeLine }.count
        #expect(includeCount == 1)
    }

    @Test func insertIsIdempotent() throws {
        let once = try Guard.insert(into: "font_size 12\n")
        let twice = try Guard.insert(into: once)
        #expect(once == twice)
        let markers = once.components(separatedBy: "\n").filter { $0 == Guard.beginMarker }.count
        #expect(markers == 1)
    }

    @Test func insertPlacesBlockAtTopAndKeepsUserContentAsSuffix() throws {
        let original = "font_size 12\nbackground #000000\n"
        let inserted = try Guard.insert(into: original)
        // Block first (so the managed include is evaluated before user settings),
        // user content preserved verbatim as the suffix.
        #expect(inserted.hasPrefix(Guard.beginMarker))
        #expect(inserted.hasSuffix(original))
    }

    @Test func roundTripRestoresNewlineTerminatedContent() throws {
        let original = "font_size 12\nbackground #000000\n"
        let restored = try Guard.remove(from: Guard.insert(into: original))
        #expect(restored == original)
    }

    @Test func roundTripRestoresContentWithoutTrailingNewline() throws {
        let original = "font_size 12"
        let restored = try Guard.remove(from: Guard.insert(into: original))
        #expect(restored == original)
    }

    @Test func roundTripRestoresEmptyContent() throws {
        let inserted = try Guard.insert(into: "")
        #expect(Guard.contains(in: inserted))
        #expect(try Guard.remove(from: inserted).isEmpty)
    }

    @Test func roundTripRestoresCRLFContentByteForByte() throws {
        let original = "font_size 12\r\nbackground #000000\r\n"
        let inserted = try Guard.insert(into: original)

        #expect(inserted.contains("\r\n"))
        #expect(try Guard.remove(from: inserted) == original)
    }

    @Test func corruptedAnchorStatesThrowSafetyError() throws {
        let cases = [
            ("begin without end", "\(Guard.beginMarker)\nfont_size 12\n", 1),
            ("end without begin", "font_size 12\n\(Guard.endMarker)\n", 2),
            ("duplicate begin", "\(Guard.beginMarker)\n\(Guard.endMarker)\n\(Guard.beginMarker)\n\(Guard.endMarker)\n", 3),
            ("duplicate end", "\(Guard.beginMarker)\n\(Guard.endMarker)\n\(Guard.endMarker)\n", 3),
            ("drift", "\(Guard.beginMarker)\n# edited\n\(Guard.includeLine)\n\(Guard.endMarker)\n", 1),
        ]

        for (name, content, line) in cases {
            do {
                _ = try Guard.insert(into: content)
                Issue.record("Expected corrupted anchor error for \(name)")
            } catch SafetyError.corruptedAnchor(let issue) {
                #expect(issue.line == line)
                #expect(issue.description.contains("Nothing was changed"))
                #expect(issue.repair.contains("kittymgr init"))
            }
        }
    }

    @Test func legacyAnchorCanBeRemovedForMigration() throws {
        let original = [
            Guard.beginMarker,
            "# Managed by kittymgr. Do not edit inside these markers.",
            Guard.legacyIncludeLine,
            Guard.endMarker,
            "",
            "font_size 12",
        ].joined(separator: "\n")

        #expect(try Guard.state(of: original) == .legacy)
        #expect(try Guard.remove(from: original) == "font_size 12")
    }
}
