import Foundation

/// `list`: print the names of all stored profiles.
public struct ListCommand {
    public let store: ProfileStore

    public init(store: ProfileStore) {
        self.store = store
    }

    public func run(log: (String) -> Void = { print($0) }) throws {
        let names = try store.list()
        if names.isEmpty {
            log("No profiles yet. Create one with: kittymgr create <name>")
            return
        }
        for name in names {
            log(name)
        }
    }
}
