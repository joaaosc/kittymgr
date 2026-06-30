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

    @Test func insertIsIdempotent() {
        let once = Guard.insert(into: "font_size 12\n")
        let twice = Guard.insert(into: once)
        #expect(once == twice)
        let markers = once.components(separatedBy: "\n").filter { $0 == Guard.beginMarker }.count
        #expect(markers == 1)
    }

    @Test func insertPlacesBlockAtTopAndKeepsUserContentAsSuffix() {
        let original = "font_size 12\nbackground #000000\n"
        let inserted = Guard.insert(into: original)
        // Block first (so the managed include is evaluated before user settings),
        // user content preserved verbatim as the suffix.
        #expect(inserted.hasPrefix(Guard.beginMarker))
        #expect(inserted.hasSuffix(original))
    }

    @Test func roundTripRestoresNewlineTerminatedContent() {
        let original = "font_size 12\nbackground #000000\n"
        let restored = Guard.remove(from: Guard.insert(into: original))
        #expect(restored == original)
    }

    @Test func roundTripRestoresContentWithoutTrailingNewline() {
        let original = "font_size 12"
        let restored = Guard.remove(from: Guard.insert(into: original))
        #expect(restored == original)
    }

    @Test func roundTripRestoresEmptyContent() {
        let inserted = Guard.insert(into: "")
        #expect(Guard.contains(in: inserted))
        #expect(Guard.remove(from: inserted).isEmpty)
    }
}
