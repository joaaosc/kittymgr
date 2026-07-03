import Foundation
import Testing
@testable import KittymgrCore

struct ConfigStoreTests {
    private let fm = FileManager.default

    @Test func atomicWritePreservesSymlinkAndWritesTarget() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-configstore-\(UUID().uuidString)")
        let dotfiles = root.appendingPathComponent("dotfiles")
        let link = root.appendingPathComponent("kitty.conf")
        let target = dotfiles.appendingPathComponent("kitty.conf")
        try fm.createDirectory(at: dotfiles, withIntermediateDirectories: true)
        try "font_size 12\n".write(to: target, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "dotfiles/kitty.conf")

        try ConfigStore.writeAtomically("font_size 18\n", to: link)

        #expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) == "dotfiles/kitty.conf")
        #expect(try String(contentsOf: target, encoding: .utf8) == "font_size 18\n")
        #expect(try String(contentsOf: link, encoding: .utf8) == "font_size 18\n")
    }

    @Test func atomicWriteRejectsSymlinkLoop() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-configstore-\(UUID().uuidString)")
        let link = root.appendingPathComponent("kitty.conf")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "kitty.conf")

        #expect(throws: ConfigStoreError.self) {
            try ConfigStore.writeAtomically("font_size 18\n", to: link)
        }
    }
}
