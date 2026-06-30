import Foundation
@testable import KittymgrCore

/// Deterministic validator stub so command tests never shell out to kitty.
struct StubValidator: ConfigValidating {
    let result: ValidationResult
    init(_ result: ValidationResult) { self.result = result }
    func validate(content: String) -> ValidationResult { result }
}
