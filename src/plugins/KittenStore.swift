import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Provenance for an installed kitten: where it came from, when it was installed,
/// its checksum (for a single-file kitten), and the entry file to invoke.
public struct KittenManifest: Codable, Equatable, Sendable {
    public let name: String
    public let source: String
    public let installedAt: String
    public let checksum: String?
    public let entry: String?
}

public enum KittenError: Error, CustomStringConvertible, Equatable {
    case sourceMissing(String)
    case alreadyInstalled(String)
    case notFound(String)
    case unsafePath(String)

    public var description: String {
        switch self {
        case let .sourceMissing(path): return "kitten source not found: \(path)"
        case let .alreadyInstalled(name): return "kitten '\(name)' is already installed"
        case let .notFound(name): return "kitten '\(name)' is not installed"
        case let .unsafePath(name): return "refusing to operate on '\(name)': resolved path escapes the kittens directory"
        }
    }
}

/// Installs, lists, and removes kittens in isolated directories under
/// `managed/kittens/<name>/`.
///
/// Security posture: this store only *copies files*. It never executes a kitten,
/// neither on install nor on config load — invocation is always an explicit user
/// action (`kitty +kitten <path>`). Each install records provenance (source and,
/// for a single-file kitten, a SHA-256 checksum) for later audit.
public struct KittenStore {
    public let root: URL
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
        self.fileManager = fileManager
    }

    public func directory(for name: PluginName) -> URL {
        root.appendingPathComponent(name.value, isDirectory: true)
    }

    public func exists(_ name: PluginName) -> Bool {
        var isDirectory: ObjCBool = false
        let present = fileManager.fileExists(atPath: directory(for: name).path, isDirectory: &isDirectory)
        return present && isDirectory.boolValue
    }

    /// Installed kittens with their provenance, sorted by name.
    public func list() -> [KittenManifest] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false }
            .map { manifest(in: $0) }
            .sorted { $0.name < $1.name }
    }

    /// Copy a kitten from `source` into its own isolated directory. The directory is
    /// staged under a temp name and published with an atomic rename, so an
    /// interrupted install never leaves a half-copied kitten.
    @discardableResult
    public func install(_ name: PluginName, from source: URL, now: Date = Date()) throws -> KittenManifest {
        guard fileManager.fileExists(atPath: source.path) else {
            throw KittenError.sourceMissing(source.path)
        }
        guard !exists(name) else {
            throw KittenError.alreadyInstalled(name.value)
        }

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".\(name.value).tmp.\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        var isSourceDir: ObjCBool = false
        fileManager.fileExists(atPath: source.path, isDirectory: &isSourceDir)

        var entry: String?
        var checksum: String?
        if isSourceDir.boolValue {
            for item in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: []) {
                try fileManager.copyItem(at: item, to: staging.appendingPathComponent(item.lastPathComponent))
            }
        } else {
            let fileName = source.lastPathComponent
            try fileManager.copyItem(at: source, to: staging.appendingPathComponent(fileName))
            entry = fileName
            checksum = try? sha256(of: source)
        }

        let manifest = KittenManifest(
            name: name.value,
            source: source.path,
            installedAt: Self.iso8601(now),
            checksum: checksum,
            entry: entry
        )
        let data = try Self.encoder.encode(manifest)
        try data.write(to: staging.appendingPathComponent(".kitten.json"), options: .atomic)

        try fileManager.moveItem(at: staging, to: directory(for: name))
        return manifest
    }

    /// Remove an installed kitten, leaving no residue. Confined to `root`.
    public func remove(_ name: PluginName) throws {
        let directory = directory(for: name)
        guard isContained(directory, in: root) else {
            throw KittenError.unsafePath(name.value)
        }
        guard exists(name) else {
            throw KittenError.notFound(name.value)
        }
        try fileManager.removeItem(at: directory)
    }

    // MARK: - Internals

    private func manifest(in directory: URL) -> KittenManifest {
        let manifestURL = directory.appendingPathComponent(".kitten.json")
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? Self.decoder.decode(KittenManifest.self, from: data) {
            return manifest
        }
        // Fall back to a minimal manifest for a directory placed there by hand.
        return KittenManifest(
            name: directory.lastPathComponent,
            source: "(unknown)",
            installedAt: "(unknown)",
            checksum: nil,
            entry: nil
        )
    }

    private func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isContained(_ url: URL, in root: URL) -> Bool {
        let resolved = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return resolved != base && resolved.hasPrefix(base + "/")
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
