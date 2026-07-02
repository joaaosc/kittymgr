import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// One tracked file inside a snapshot: its path relative to the kitty config
/// directory, the SHA-256 of its bytes, and its size.
public struct SnapshotEntry: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let size: Int
}

/// Immutable description of a captured snapshot. Serialized as JSON and published
/// atomically; the set of published manifests *is* the history.
public struct SnapshotManifest: Codable, Equatable, Sendable {
    public let id: String
    public let createdAt: String
    public let label: String?
    public let files: [SnapshotEntry]
}

public enum BackupError: Error, CustomStringConvertible, Equatable {
    case notFound(String)

    public var description: String {
        switch self {
        case .notFound(let id): return "snapshot not found: \(id)"
        }
    }
}

/// Append-only, content-addressed snapshot store for the managed configuration
/// surface (the user `kitty.conf` plus everything under `managed/`, excluding the
/// backup store itself).
///
/// Versioning backend decision: kittymgr keeps its own content-addressed
/// snapshots (SHA-256 object store + JSON manifests) rather than embedding a git
/// repository. This removes any runtime dependency on a `git` binary, stays
/// deterministic and portable across platforms, deduplicates unchanged files for
/// free, and lets the manifest publish be the single atomic commit point. The
/// trade-off — no packing/compression and a hand-written diff — is acceptable for
/// the small text configs this tool manages.
///
/// On-disk layout under `managed/backups/`:
/// - `objects/<sha256>` — unique file contents, written before the manifest.
/// - `snapshots/<id>.json` — a manifest, published last via atomic rename.
///
/// Atomicity: object writes and the manifest write both go through a temp file +
/// rename (`Data.write(options: .atomic)`). A crash before the manifest rename
/// leaves only orphan objects, never a partial history entry, so `list()` is
/// always consistent.
public struct SnapshotStore {
    public let configDir: ConfigDir

    public init(configDir: ConfigDir) {
        self.configDir = configDir
    }

    private var objectsDir: URL { configDir.backupsDir.appendingPathComponent("objects") }
    private var snapshotsDir: URL { configDir.backupsDir.appendingPathComponent("snapshots") }

    // MARK: Capture

    /// Capture the current managed surface as a new snapshot and publish it.
    @discardableResult
    public func create(label: String? = nil, now: Date = Date()) throws -> SnapshotManifest {
        let fm = FileManager.default
        try fm.createDirectory(at: objectsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)

        var entries: [SnapshotEntry] = []
        for file in trackedFiles() {
            let data = try Data(contentsOf: file)
            let sha = Self.sha256Hex(data)
            let object = objectsDir.appendingPathComponent(sha)
            if !fm.fileExists(atPath: object.path) {
                try data.write(to: object, options: .atomic)
            }
            entries.append(SnapshotEntry(path: relativePath(of: file), sha256: sha, size: data.count))
        }

        let id = uniqueID(now: now)
        let manifest = SnapshotManifest(id: id, createdAt: Self.iso8601(now), label: label, files: entries)
        let json = try Self.encoder.encode(manifest)
        // Publish: this atomic rename is the single point at which the snapshot
        // becomes visible to `list()`.
        try json.write(to: snapshotsDir.appendingPathComponent(id + ".json"), options: .atomic)
        return manifest
    }

    // MARK: History

    /// All published snapshots, newest first (ids sort chronologically).
    public func list() -> [SnapshotManifest] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(SnapshotManifest.self, from: Data(contentsOf: $0)) }
            .sorted { $0.id > $1.id }
    }

    /// Resolve a snapshot by exact id, or by a unique id prefix for convenience.
    public func manifest(matching id: String) -> SnapshotManifest? {
        let all = list()
        if let exact = all.first(where: { $0.id == id }) { return exact }
        let prefixed = all.filter { $0.id.hasPrefix(id) }
        return prefixed.count == 1 ? prefixed.first : nil
    }

    // MARK: Integrity

    /// Snapshot entries whose backing object is missing from the store, as
    /// `"<snapshotID>:<path>"` — a corruption signal for `doctor`. Empty when the
    /// store is consistent (a restore would succeed for every published snapshot).
    public func missingObjects() -> [String] {
        let fm = FileManager.default
        var missing: [String] = []
        for manifest in list() {
            for entry in manifest.files
            where !fm.fileExists(atPath: objectsDir.appendingPathComponent(entry.sha256).path) {
                missing.append("\(manifest.id):\(entry.path)")
            }
        }
        return missing
    }

    /// Object hashes present in the store but referenced by no snapshot — safe to
    /// garbage-collect (used by `clean`). Removing them cannot lose history.
    public func unreferencedObjects() -> [String] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: objectsDir, includingPropertiesForKeys: nil) else { return [] }
        let referenced = Set(list().flatMap { $0.files.map(\.sha256) })
        return files.map { $0.lastPathComponent }.filter { !referenced.contains($0) }
    }

    /// Delete the given object hashes from the store.
    public func removeObjects(_ hashes: [String]) {
        let fm = FileManager.default
        for hash in hashes {
            try? fm.removeItem(at: objectsDir.appendingPathComponent(hash))
        }
    }

    // MARK: Restore

    /// Restore the managed surface to a byte-for-byte copy of `manifest`: every
    /// tracked file present then is rewritten, and any file added since is removed.
    public func restore(_ manifest: SnapshotManifest) throws {
        let fm = FileManager.default
        let wanted = Set(manifest.files.map(\.path))

        for file in trackedFiles() where !wanted.contains(relativePath(of: file)) {
            try fm.removeItem(at: file)
        }

        for entry in manifest.files {
            let destination = configDir.url.appendingPathComponent(entry.path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Data(contentsOf: objectsDir.appendingPathComponent(entry.sha256))
            try data.write(to: destination, options: .atomic)
        }
    }

    /// Restore the tracked surface to a previously captured byte-exact map (from
    /// `currentSurface()`): every file present then is rewritten byte-for-byte and
    /// any file added since is removed. Binary-safe; used to revert a previewed
    /// change without creating a history entry.
    public func restore(toSurface surface: [String: Data]) throws {
        let fm = FileManager.default
        let wanted = Set(surface.keys)
        for file in trackedFiles() where !wanted.contains(relativePath(of: file)) {
            try fm.removeItem(at: file)
        }
        for (path, data) in surface {
            let destination = configDir.url.appendingPathComponent(path)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        }
    }

    // MARK: State (for diffing)

    /// Current text contents of the managed surface keyed by relative path.
    /// Text-only: undecodable/binary files are skipped, so this is for rendering
    /// diffs, never for reverting — use `currentSurface()`/`restore(toSurface:)` to
    /// avoid deleting binary files.
    public func currentContents() -> [String: String] {
        var map: [String: String] = [:]
        for file in trackedFiles() {
            if let text = try? String(contentsOf: file, encoding: .utf8) {
                map[relativePath(of: file)] = text
            }
        }
        return map
    }

    /// Byte-exact contents of the managed surface keyed by relative path, including
    /// binary files. The safe capture for reverting a previewed change.
    public func currentSurface() throws -> [String: Data] {
        var map: [String: Data] = [:]
        for file in trackedFiles() {
            map[relativePath(of: file)] = try Data(contentsOf: file)
        }
        return map
    }

    /// Text contents stored in a snapshot keyed by relative path.
    public func contents(of manifest: SnapshotManifest) throws -> [String: String] {
        var map: [String: String] = [:]
        for entry in manifest.files {
            let data = try Data(contentsOf: objectsDir.appendingPathComponent(entry.sha256))
            map[entry.path] = String(decoding: data, as: UTF8.self)
        }
        return map
    }

    // MARK: Tracked surface

    /// The managed surface: `kitty.conf` plus every regular file under `managed/`,
    /// excluding the backup store and the source cache. Sorted for deterministic
    /// snapshots.
    func trackedFiles() -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []

        if fm.fileExists(atPath: configDir.kittyConf.path) {
            result.append(configDir.kittyConf)
        }

        // Never snapshot the backup store or the remote-source cache: both live
        // under managed/ but are derived data, not part of the configuration.
        let excluded: Set<String> = [
            configDir.backupsDir.standardizedFileURL.path,
            configDir.managedDir.appendingPathComponent(".cache").standardizedFileURL.path,
        ]
        if let enumerator = fm.enumerator(
            at: configDir.managedDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for case let url as URL in enumerator {
                let path = url.standardizedFileURL.path
                if excluded.contains(path) {
                    enumerator.skipDescendants()
                    continue
                }
                var isDir: ObjCBool = false
                fm.fileExists(atPath: url.path, isDirectory: &isDir)
                if !isDir.boolValue { result.append(url) }
            }
        }

        return result.sorted { relativePath(of: $0) < relativePath(of: $1) }
    }

    private func relativePath(of url: URL) -> String {
        configDir.relativePath(of: url)
    }

    // MARK: Helpers

    private func uniqueID(now: Date) -> String {
        let base = Self.idFormatter.string(from: now)
        let fm = FileManager.default
        var candidate = base
        var counter = 1
        while fm.fileExists(atPath: snapshotsDir.appendingPathComponent(candidate + ".json").path) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()
}
