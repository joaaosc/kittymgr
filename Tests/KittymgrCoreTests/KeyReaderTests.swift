import Foundation
import Testing
@testable import KittymgrCore

struct KeyReaderTests {
    @Test func decodesMultibyteCharacters() {
        let cases: [(Character, [UInt8])] = [
            ("ç", Array("ç".utf8)),
            ("á", Array("á".utf8)),
            ("é", Array("é".utf8)),
            ("ã", Array("ã".utf8)),
        ]

        for (character, bytes) in cases {
            #expect(readKey([bytes]) == .char(character))
        }
    }

    @Test func decodesMultibyteCharactersSplitAcrossReads() {
        let cedilla = Array("ç".utf8).map { [$0] }
        let accentedA = Array("ã".utf8).map { [$0] }

        #expect(readKey(cedilla) == .char("ç"))
        #expect(readKey(accentedA) == .char("ã"))
    }

    @Test func preservesAsciiAndControlKeys() {
        #expect(readKey([[UInt8(ascii: "a")]]) == .char("a"))
        #expect(readKey([[3]]) == .ctrlC)
        #expect(readKey([[10]]) == .enter)
        #expect(readKey([[13]]) == .enter)
        #expect(readKey([[9]]) == .tab)
        #expect(readKey([[127]]) == .backspace)
        #expect(readKey([[8]]) == .backspace)
    }

    @Test func preservesEscapeAndArrowKeys() {
        #expect(readKey([[27]]) == .escape)
        #expect(readKey([[27, 91, 65]]) == .up)
        #expect(readKey([[27, 91, 66]]) == .down)
        #expect(readKey([[27, 91, 67]]) == .right)
        #expect(readKey([[27, 91, 68]]) == .left)
        #expect(readKey([[27, 91, 88]]) == .escape)
    }

    @Test func invalidUTF8ReturnsUnknown() {
        #expect(readKey([[0x80]]) == .unknown)
        #expect(readKey([[0xC0, 0x80]]) == .unknown)
        #expect(readKey([[0xC3], [0x28]]) == .unknown)
        #expect(readKey([[0xE2]]) == .unknown)
    }

    private func readKey(_ chunks: [[UInt8]]) -> TUIKey {
        var chunks = chunks
        return KeyReader.readKey { maxCount in
            guard chunks.isEmpty == false else { return [] }

            let next = chunks.removeFirst()
            guard next.count > maxCount else { return next }

            chunks.insert(Array(next.dropFirst(maxCount)), at: 0)
            return Array(next.prefix(maxCount))
        }
    }
}
