import Foundation

/// A pinned source: the exact version resolved at lock time, so a `sync` on another
/// machine reproduces the same content.
public struct LockedSource: Codable, Equatable, Sendable {
    public let name: String
    public let git: String?
    public let url: String?
    public let resolvedRef: String?
    public let checksum: String?
    public let lockedAt: String

    public init(name: String, git: String? = nil, url: String? = nil, resolvedRef: String? = nil, checksum: String? = nil, lockedAt: String) {
        self.name = name
        self.git = git
        self.url = url
        self.resolvedRef = resolvedRef
        self.checksum = checksum
        self.lockedAt = lockedAt
    }
}

/// Machine-generated `kittymgr.lock` (JSON): the resolved version of every source.
/// Not meant to be hand-edited.
public struct Lockfile: Codable, Equatable, Sendable {
    public var sources: [LockedSource]

    public init(sources: [LockedSource] = []) {
        self.sources = sources
    }

    public static func load(_ url: URL) -> Lockfile {
        guard let data = try? Data(contentsOf: url),
              let lock = try? JSONDecoder().decode(Lockfile.self, from: data)
        else { return Lockfile() }
        return lock
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func entry(for name: String) -> LockedSource? {
        sources.first { $0.name == name }
    }

    public mutating func upsert(_ locked: LockedSource) {
        sources.removeAll { $0.name == locked.name }
        sources.append(locked)
        sources.sort { $0.name < $1.name }
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
