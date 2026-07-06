import Testing
@testable import KittymgrCore

struct ConsoleStyleTests {
    @Test func paintWrapsOnlyWhenEnabled() {
        #expect(ConsoleStyle.paint("hello", code: "1", enabled: false) == "hello")
        #expect(ConsoleStyle.paint("hello", code: "1", enabled: true) == "\u{001B}[1mhello\u{001B}[0m")
        #expect(ConsoleStyle.paint("err", code: "31;1", enabled: true) == "\u{001B}[31;1merr\u{001B}[0m")
    }

    @Test func disabledStylingIsByteIdenticalPlainText() {
        // Scripts and pipes must never see escape codes.
        let samples = ["kittymgr", "Switched to 'work'.", "error: boom", ""]
        for text in samples {
            #expect(ConsoleStyle.paint(text, code: "32", enabled: false) == text)
        }
    }
}
