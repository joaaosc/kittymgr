import Foundation
@testable import KittymgrCore

/// Deterministic validator stub so command tests never shell out to kitty.
struct StubValidator: ConfigValidating {
    let result: ValidationResult
    init(_ result: ValidationResult) { self.result = result }
    func validate(content: String) -> ValidationResult { result }
}

final class ScriptedTerminal: TerminalControlling, @unchecked Sendable {
    var isInteractive: Bool
    var size: (rows: Int, cols: Int)
    private(set) var enableCalls = 0
    private(set) var disableCalls = 0

    init(isInteractive: Bool = true, size: (rows: Int, cols: Int) = (30, 100)) {
        self.isInteractive = isInteractive
        self.size = size
    }

    func getSize() -> (rows: Int, cols: Int) { size }

    func enableRawMode() throws {
        enableCalls += 1
    }

    func disableRawMode() {
        disableCalls += 1
    }
}
