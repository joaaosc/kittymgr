import Foundation

/// Safely enumerates, creates, and deletes profile directories under a fixed root
/// (`managed/profiles/`). All mutating operations are confined to that root.
public struct ProfileStore {
    public let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    /// Directory that a profile maps to. The name is pre-validated, so this join
    /// cannot escape `root`.
    public func directory(for name: ProfileName) -> URL {
        root.appendingPathComponent(name.value, isDirectory: true)
    }

    /// Profile directory names, sorted case-insensitively. Ignores files and
    /// hidden entries so the listing stays robust.
    public func list() throws -> [String] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let directories = entries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }
        return directories
            .map(\.lastPathComponent)
            .sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Names of the `.conf` files in a profile, lexically sorted for reproducible
    /// include ordering. Ignores subdirectories and hidden entries.
    public func confFiles(in name: ProfileName) throws -> [String] {
        let directory = directory(for: name)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let confs = entries.filter { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return !isDirectory && url.pathExtension == "conf"
        }
        return confs.map(\.lastPathComponent).sorted()
    }

    /// Per-profile metadata file (`profile.json`).
    public func metadataURL(for name: ProfileName) -> URL {
        directory(for: name).appendingPathComponent("profile.json")
    }

    /// Load a profile's metadata, returning defaults when absent or unreadable so
    /// a bare folder of `.conf` files stays valid.
    public func metadata(for name: ProfileName) -> ProfileMetadata {
        guard let data = try? Data(contentsOf: metadataURL(for: name)),
              let metadata = try? JSONDecoder().decode(ProfileMetadata.self, from: data)
        else {
            return ProfileMetadata()
        }
        return metadata
    }

    public func setMetadata(_ metadata: ProfileMetadata, for name: ProfileName) throws {
        try fileManager.createDirectory(at: directory(for: name), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: metadataURL(for: name), options: .atomic)
    }

    /// Exact-case existence check.
    public func exists(_ name: ProfileName) -> Bool {
        var isDirectory: ObjCBool = false
        let present = fileManager.fileExists(
            atPath: directory(for: name).path,
            isDirectory: &isDirectory
        )
        return present && isDirectory.boolValue
    }

    /// Create an empty profile directory. Fails if a profile with the same name
    /// already exists, comparing case-insensitively to avoid collisions on
    /// case-insensitive filesystems (APFS default).
    @discardableResult
    public func create(_ name: ProfileName) throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        if let existing = try existingNameMatching(name) {
            throw ProfileError.alreadyExists(existing)
        }
        let directory = directory(for: name)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    /// Remove a profile directory. Refuses if the resolved path escapes `root`
    /// or if the profile does not exist.
    public func delete(_ name: ProfileName) throws {
        let directory = directory(for: name)
        guard isContained(directory, in: root) else {
            throw ProfileError.unsafePath(name.value)
        }
        guard exists(name) else {
            throw ProfileError.notFound(name.value)
        }
        try fileManager.removeItem(at: directory)
    }

    // MARK: - Internals

    /// Resolves `name` to the exact case-sensitive name present on disk if a
    /// case-insensitive match is found; otherwise returns `name` unchanged.
    public func resolveName(_ name: ProfileName) throws -> ProfileName {
        if let existing = try existingNameMatching(name) {
            return try ProfileName(validating: existing)
        }
        return name
    }

    private func existingNameMatching(_ name: ProfileName) throws -> String? {
        let target = name.value.lowercased()
        return try list().first { $0.lowercased() == target }
    }

    private func isContained(_ url: URL, in root: URL) -> Bool {
        let resolved = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return resolved != base && resolved.hasPrefix(base + "/")
    }
}
