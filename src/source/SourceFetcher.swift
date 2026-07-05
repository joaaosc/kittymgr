import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Fetches a `Source` into the local cache. Injectable so higher layers (install,
/// sync) can be tested with a stub that never touches the network or git.
public protocol SourceFetching {
    func fetch(_ source: Source) throws -> FetchedSource
    /// Drop any cached copy so the next fetch re-resolves (used by `update`).
    func invalidate(_ source: Source)
    /// Resolve the newest commit a git source's ref points to on the remote,
    /// *without* fetching or mutating the cache. Returns nil when not applicable
    /// (URL/local sources) or unresolvable. Used by `update --check`.
    func resolveLatest(_ source: Source) throws -> String?
}

public extension SourceFetching {
    func invalidate(_ source: Source) {}
    func resolveLatest(_ source: Source) throws -> String? { nil }
}

/// Default fetcher: git repositories via the `git` binary, URLs via a bounded
/// synchronous download (scheme allowlist, timeouts, size cap — see
/// `URLDownloader`), local paths in place. Never executes fetched content.
public struct DefaultSourceFetcher: SourceFetching {
    public let cacheDir: URL
    private let fileManager: FileManager
    private let download: (URL) throws -> Data

    /// `download` is injectable so the URL path can be tested without network;
    /// the default enforces the release download policy.
    public init(
        cacheDir: URL,
        fileManager: FileManager = .default,
        download: @escaping (URL) throws -> Data = { try URLDownloader().download($0) }
    ) {
        self.cacheDir = cacheDir
        self.fileManager = fileManager
        self.download = download
    }

    public func fetch(_ source: Source) throws -> FetchedSource {
        switch source.kind {
        case let .git(url, ref):
            return try fetchGit(url: url, ref: ref, destination: cacheEntry(for: source))
        case let .url(url):
            return try fetchURL(url, destination: cacheEntry(for: source))
        case let .local(path):
            return try fetchLocal(path)
        }
    }

    public func invalidate(_ source: Source) {
        try? fileManager.removeItem(at: cacheEntry(for: source))
    }

    /// Resolve the remote's current commit for a git source via `git ls-remote`
    /// (no clone, no cache write). A full commit SHA is already pinned and returned
    /// as-is; a tag resolves to its (stable) commit; a branch or the default HEAD
    /// resolves to the current tip — so only floating refs can appear "outdated".
    public func resolveLatest(_ source: Source) throws -> String? {
        guard case let .git(url, ref) = source.kind else { return nil }
        guard !url.hasPrefix("-") else {
            throw SourceError.fetchFailed(source: url, detail: "git URL cannot start with '-'")
        }
        if let ref, ref.hasPrefix("-") {
            throw SourceError.fetchFailed(source: url, detail: "git ref cannot start with '-'")
        }
        if let ref, Self.isFullCommitSHA(ref) { return ref }

        let result = try run("git", ["ls-remote", url, ref ?? "HEAD"])
        guard result.status == 0 else {
            throw SourceError.fetchFailed(source: url, detail: result.stderr)
        }
        return Self.parseLsRemote(result.stdout)
    }

    private static func isFullCommitSHA(_ ref: String) -> Bool {
        (ref.count == 40 || ref.count == 64) && ref.allSatisfy(\.isHexDigit)
    }

    private static func parseLsRemote(_ stdout: String) -> String? {
        let lines = stdout.split(separator: "\n").map(String.init)
        // Prefer the dereferenced tag commit (`<ref>^{}`) when present.
        let chosen = lines.first(where: { $0.contains("^{}") }) ?? lines.first
        return chosen?.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init)
    }

    // MARK: - git

    private func fetchGit(url: String, ref: String?, destination: URL) throws -> FetchedSource {
        guard !url.hasPrefix("-") else {
            throw SourceError.fetchFailed(source: url, detail: "git URL cannot start with '-'")
        }
        if let ref {
            guard !ref.hasPrefix("-") else {
                throw SourceError.fetchFailed(source: url, detail: "git ref cannot start with '-'")
            }
        }

        // Reuse an existing checkout; refreshing to a newer ref is `update`'s job.
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let staging = cacheDir.appendingPathComponent(".clone.\(UUID().uuidString)")

            var cloneArgs = ["clone", "--depth", "1"]
            if let ref { cloneArgs += ["--branch", ref] }
            cloneArgs += ["--", url, staging.path]

            let clone = try run("git", cloneArgs)
            if clone.timedOut {
                // A hung clone is a hard failure; the SHA fallback below is
                // only for the fast `--branch`-rejects-a-commit error.
                try? fileManager.removeItem(at: staging)
                throw SourceError.fetchFailed(source: url, detail: clone.stderr)
            }
            if clone.status != 0 {
                // A commit SHA cannot be used with --branch; fall back to a full
                // clone followed by an explicit checkout.
                try? fileManager.removeItem(at: staging)
                if let ref {
                    let full = try run("git", ["clone", "--", url, staging.path])
                    guard full.status == 0 else {
                        throw SourceError.fetchFailed(source: url, detail: full.stderr)
                    }
                    let checkout = try run("git", ["-C", staging.path, "checkout", ref])
                    guard checkout.status == 0 else {
                        try? fileManager.removeItem(at: staging)
                        throw SourceError.fetchFailed(source: url, detail: checkout.stderr)
                    }
                } else {
                    throw SourceError.fetchFailed(source: url, detail: clone.stderr)
                }
            }
            try fileManager.moveItem(at: staging, to: destination)
        }

        let head = try run("git", ["-C", destination.path, "rev-parse", "HEAD"])
        let resolved = head.status == 0
            ? head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        return FetchedSource(root: destination, resolvedRef: resolved)
    }

    // MARK: - url

    private func fetchURL(_ urlString: String, destination: URL) throws -> FetchedSource {
        guard let url = URL(string: urlString) else {
            throw SourceError.fetchFailed(source: urlString, detail: "invalid URL")
        }
        let data: Data
        do {
            data = try download(url)
        } catch let error as URLDownloadError {
            throw SourceError.fetchFailed(source: urlString, detail: error.description)
        } catch {
            throw SourceError.fetchFailed(source: urlString, detail: "\(error)")
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let fileName = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        try data.write(to: destination.appendingPathComponent(fileName), options: .atomic)
        return FetchedSource(root: destination, checksum: Self.sha256(data))
    }

    // MARK: - local

    private func fetchLocal(_ path: String) throws -> FetchedSource {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw SourceError.localMissing(path)
        }
        let url = URL(fileURLWithPath: path)
        let checksum = isDirectory.boolValue ? nil : (try? Data(contentsOf: url)).map(Self.sha256)
        return FetchedSource(root: url, resolvedRef: nil, checksum: checksum)
    }

    // MARK: - Helpers

    private func cacheEntry(for source: Source) -> URL {
        cacheDir.appendingPathComponent(Self.cacheDirectoryName(for: source))
    }

    /// The cache subdirectory name a source resolves to. Exposed so `clean` can tell
    /// which cache entries still belong to a manifest source and which are orphans.
    public static func cacheDirectoryName(for source: Source) -> String {
        String(sha256(Data(source.cacheKey.utf8)).prefix(16))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Wall-clock budget per git invocation; a legitimate remote clone can be
    /// slow, but a hung one must not stall a run forever.
    private static let toolTimeout: TimeInterval = 300

    private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String, timedOut: Bool) {
        let result: ProcessOutput
        do {
            result = try ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: [tool] + arguments,
                timeout: Self.toolTimeout
            )
        } catch {
            throw SourceError.toolMissing(tool)
        }
        if !result.timedOut, result.status == 127 {
            throw SourceError.toolMissing(tool)
        }
        var stderrText = String(decoding: result.stderr, as: UTF8.self)
        if result.timedOut {
            let note = "timed out after \(Int(Self.toolTimeout))s"
            stderrText = stderrText.isEmpty ? note : stderrText + "\n(\(note))"
        }
        return (
            result.timedOut ? -1 : result.status,
            String(decoding: result.stdout, as: UTF8.self),
            stderrText,
            result.timedOut
        )
    }
}
