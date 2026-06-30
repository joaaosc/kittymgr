import Foundation
import Testing
@testable import KittymgrCore

struct UnifiedDiffTests {
    @Test func identicalProducesEmpty() {
        #expect(UnifiedDiff.diff(old: "a\nb\n", new: "a\nb\n", oldLabel: "a/x", newLabel: "b/x") == "")
    }

    @Test func modificationShowsContextAddAndRemove() {
        let diff = UnifiedDiff.diff(old: "a\nb\nc\n", new: "a\nB\nc\n", oldLabel: "a/x", newLabel: "b/x")
        #expect(diff.hasPrefix("--- a/x\n+++ b/x\n"))
        #expect(diff.contains("@@"))
        #expect(diff.contains("\n-b\n"))
        #expect(diff.contains("\n+B\n"))
        #expect(diff.contains("\n a\n"))  // surrounding context preserved
        #expect(diff.contains("\n c\n"))
    }

    @Test func pureInsertionAndDeletion() {
        let added = UnifiedDiff.diff(old: "a\n", new: "a\nb\n", oldLabel: "o", newLabel: "n")
        #expect(added.contains("\n+b\n"))
        let removed = UnifiedDiff.diff(old: "a\nb\n", new: "a\n", oldLabel: "o", newLabel: "n")
        #expect(removed.contains("\n-b\n"))
    }

    @Test func diffStatesHandlesAddedRemovedModified() {
        let out = UnifiedDiff.diffStates(
            old: ["keep": "x\n", "gone": "old\n"],
            new: ["keep": "x\n", "added": "new\n"]
        )
        #expect(out.contains("--- a/gone"))
        #expect(out.contains("+++ /dev/null"))
        #expect(out.contains("--- /dev/null"))
        #expect(out.contains("+++ b/added"))
        #expect(out.contains("\n-old\n"))
        #expect(out.contains("\n+new\n"))
        // An unchanged file contributes no hunk.
        #expect(out.contains("keep") == false)
    }
}
