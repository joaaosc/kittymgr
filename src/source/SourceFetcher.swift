import Foundation
import CryptoKit

/// Fetches a `Source` into the local cache. Injectable so higher layers (install,
/// sync) can be tested with a stub that never touches the network or git.
public protocol SourceFetching {
    func fetch(_ source: Source) throws -> FetchedSource
    /// Drop any cached copy so the next fetch re-resolves (used by `update`).
    func invalidate(_ source: Source)
}

public extension SourceFetching {
    func invalidate(_ source: Source) {}
}

/// Default fetcher: git repositories via the `git` binary, URLs via a synchronous
/// download, local paths in place. Never executes fetched content.
public struct DefaultSourceFetcher: SourceFetching {
    public let cacheDir: URL
    private let fileManager: FileManager

    public init(cacheDir: URL, fileManager: FileManager = .default) {
        self.cacheDir = cacheDir
        self.fileManager = fileManager
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
            data = try Data(contentsOf: url)
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
        let digest = Self.sha256(Data(source.cacheKey.utf8)).prefix(16)
        return cacheDir.appendingPathComponent(String(digest))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw SourceError.toolMissing(tool)
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus == 127 {
            throw SourceError.toolMissing(tool)
        }
        return (
            process.terminationStatus,
            String(decoding: outData, as: UTF8.self),
            String(decoding: errData, as: UTF8.self)
        )
    }
}
