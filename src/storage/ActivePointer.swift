import Foundation

/// Persists and reads the currently active profile selection.
///
/// Stored as a one-line pointer file under the managed directory. This pointer is
/// authoritative: `current` reads it and later milestones can rely on it.
public struct ActivePointer {
    public let url: URL
    private let fileManager: FileManager

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    /// The active profile name, or `nil` when none is set.
    public func get() -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func set(_ name: ProfileName) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try ConfigStore.writeAtomically(name.value + "\n", to: url)
    }

    public func clear() {
        try? fileManager.removeItem(at: url)
    }
}
