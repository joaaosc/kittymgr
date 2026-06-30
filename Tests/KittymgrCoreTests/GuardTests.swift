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

    @Test func appendIsIdempotent() {
        let once = Guard.append(to: "font_size 12\n").content
        let twice = Guard.append(to: once).content
        #expect(once == twice)
        let markers = once.components(separatedBy: "\n").filter { $0 == Guard.beginMarker }.count
        #expect(markers == 1)
    }

    @Test func appendLeavesExistingLinesUnchanged() {
        let original = "font_size 12\nbackground #000000\n"
        let appended = Guard.append(to: original).content
        #expect(appended.hasPrefix(original))
    }

    @Test func roundTripRestoresNewlineTerminatedContent() {
        let original = "font_size 12\nbackground #000000\n"
        let result = Guard.append(to: original)
        let restored = Guard.remove(from: result.content, addedTrailingNewline: result.addedTrailingNewline)
        #expect(restored == original)
    }

    @Test func roundTripRestoresContentWithoutTrailingNewline() {
        let original = "font_size 12"
        let result = Guard.append(to: original)
        #expect(result.addedTrailingNewline)
        let restored = Guard.remove(from: result.content, addedTrailingNewline: result.addedTrailingNewline)
        #expect(restored == original)
    }

    @Test func roundTripRestoresEmptyContent() {
        let result = Guard.append(to: "")
        #expect(Guard.contains(in: result.content))
        let restored = Guard.remove(from: result.content, addedTrailingNewline: result.addedTrailingNewline)
        #expect(restored.isEmpty)
    }
}
