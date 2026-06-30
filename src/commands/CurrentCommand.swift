import Foundation

/// `current`: print the active profile name.
public struct CurrentCommand {
    public let activePointer: ActivePointer

    public init(activePointer: ActivePointer) {
        self.activePointer = activePointer
    }

    public func run(log: (String) -> Void = { print($0) }) throws {
        if let name = activePointer.get() {
            log(name)
        } else {
            log("No active profile. Set one with: kittymgr switch <name>")
        }
    }
}
