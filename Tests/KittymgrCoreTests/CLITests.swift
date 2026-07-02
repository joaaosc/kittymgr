import Testing
@testable import KittymgrCore

struct CLIVersionTests {
    @Test func versionConstantIsSemver() {
        let parts = Kittymgr.version.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    }

    @Test func versionFlagExitsZero() {
        #expect(KittymgrCLI.run(["--version"]) == 0)
        #expect(KittymgrCLI.run(["-V"]) == 0)
    }

    @Test func helpFlagExitsZero() {
        #expect(KittymgrCLI.run(["--help"]) == 0)
        #expect(KittymgrCLI.run(["-h"]) == 0)
    }
}
