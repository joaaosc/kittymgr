import Foundation

/// A place kittymgr can fetch content from: a git repository, a plain URL (single
/// file or tarball), or a local path. Sources are the distribution layer that lets
/// themes, plugins, and kittens come from somewhere other than a local `--from`.
public struct Source: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A git repository. `ref` pins a branch, tag, or commit (nil = default branch).
        case git(url: String, ref: String?)
        /// A plain URL to a single file or a tarball.
        case url(String)
        /// A local directory or file already on disk.
        case local(path: String)
    }

    public let name: String
    public let kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    /// Stable identity used to key the on-disk cache. Distinct locations/refs get
    /// distinct cache entries; the same source reuses its checkout.
    public var cacheKey: String {
        switch kind {
        case let .git(url, ref): return "git\u{0}\(url)\u{0}\(ref ?? "")"
        case let .url(url): return "url\u{0}\(url)"
        case let .local(path): return "local\u{0}\(path)"
        }
    }
}

/// The result of fetching a `Source`: where the content landed plus the provenance
/// that pins it (the resolved git commit, or the checksum of a downloaded file).
public struct FetchedSource: Equatable, Sendable {
    /// Directory (for git/local dir) or the parent directory (for a downloaded file)
    /// holding the fetched content.
    public let root: URL
    /// Resolved git commit SHA, when the source is a git repository.
    public let resolvedRef: String?
    /// SHA-256 of a downloaded single file, when applicable.
    public let checksum: String?

    public init(root: URL, resolvedRef: String? = nil, checksum: String? = nil) {
        self.root = root
        self.resolvedRef = resolvedRef
        self.checksum = checksum
    }
}

public enum SourceError: Error, CustomStringConvertible, Equatable {
    case toolMissing(String)
    case fetchFailed(source: String, detail: String)
    case localMissing(String)

    public var description: String {
        switch self {
        case let .toolMissing(tool): return "required tool not found: \(tool)"
        case let .fetchFailed(source, detail): return "failed to fetch \(source): \(detail)"
        case let .localMissing(path): return "local source not found: \(path)"
        }
    }
}
