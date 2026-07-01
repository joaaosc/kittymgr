import Foundation
import Testing
@testable import KittymgrCore

struct SourceTests {
    private let fm = FileManager.default

    private func tempDir() -> URL {
        fm.temporaryDirectory.appendingPathComponent("kittymgr-src-\(UUID().uuidString)")
    }

    @Test func cacheKeyDistinguishesLocationAndRef() {
        #expect(Source(name: "a", kind: .git(url: "u", ref: "x")).cacheKey
            != Source(name: "a", kind: .git(url: "u", ref: "y")).cacheKey)
        #expect(Source(name: "a", kind: .git(url: "u", ref: nil)).cacheKey
            != Source(name: "a", kind: .url("u")).cacheKey)
        #expect(Source(name: "a", kind: .url("u")).cacheKey
            == Source(name: "b", kind: .url("u")).cacheKey)  // identity is location, not name
    }

    @Test func fetchLocalDirectoryPointsInPlace() throws {
        let dir = tempDir()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "x\n".write(to: dir.appendingPathComponent("a.conf"), atomically: true, encoding: .utf8)

        let fetcher = DefaultSourceFetcher(cacheDir: tempDir())
        let result = try fetcher.fetch(Source(name: "local", kind: .local(path: dir.path)))
        #expect(result.root.standardizedFileURL.path == dir.standardizedFileURL.path)
    }

    @Test func fetchLocalMissingThrows() {
        let fetcher = DefaultSourceFetcher(cacheDir: tempDir())
        #expect(throws: SourceError.self) {
            try fetcher.fetch(Source(name: "x", kind: .local(path: "/nope/missing")))
        }
    }

    @Test func fetchURLDownloadsAndChecksums() throws {
        // A file:// URL exercises the download path deterministically, no network.
        let sourceFile = tempDir()
        try fm.createDirectory(at: sourceFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "background #282828\n".write(to: sourceFile, atomically: true, encoding: .utf8)
        let urlString = URL(fileURLWithPath: sourceFile.path).absoluteString

        let cache = tempDir()
        let result = try DefaultSourceFetcher(cacheDir: cache).fetch(Source(name: "u", kind: .url(urlString)))

        #expect(result.checksum != nil)
        let downloaded = try fm.contentsOfDirectory(at: result.root, includingPropertiesForKeys: nil)
        #expect(downloaded.count == 1)
        #expect((try? String(contentsOf: downloaded[0], encoding: .utf8)) == "background #282828\n")
    }

    // MARK: - git (requires the `git` binary; skips if absent)

    private func gitAvailable() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "--version"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    @discardableResult
    private func git(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func makeRepo(file: String, content: String) throws -> URL {
        let repo = tempDir()
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        git(["-C", repo.path, "init", "-q"])
        git(["-C", repo.path, "config", "user.email", "t@example.com"])
        git(["-C", repo.path, "config", "user.name", "Test"])
        let fileURL = repo.appendingPathComponent(file)
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        git(["-C", repo.path, "add", "-A"])
        git(["-C", repo.path, "commit", "-q", "-m", "init"])
        return repo
    }

    @Test func fetchGitClonesAndResolvesCommitThenReusesCache() throws {
        guard gitAvailable() else { return }
        let repo = try makeRepo(file: "themes/Gruvbox.conf", content: "background #282828\n")
        let cache = tempDir()
        let fetcher = DefaultSourceFetcher(cacheDir: cache)

        let first = try fetcher.fetch(Source(name: "themes", kind: .git(url: repo.path, ref: nil)))
        #expect(first.resolvedRef?.count == 40)  // full commit SHA
        #expect(fm.fileExists(atPath: first.root.appendingPathComponent("themes/Gruvbox.conf").path))

        // Second fetch reuses the same cache entry (same resolved commit).
        let second = try fetcher.fetch(Source(name: "themes", kind: .git(url: repo.path, ref: nil)))
        #expect(second.root.path == first.root.path)
        #expect(second.resolvedRef == first.resolvedRef)
    }

    @Test func fetchGitOptionInjectionThrows() {
        let fetcher = DefaultSourceFetcher(cacheDir: tempDir())
        #expect(throws: SourceError.self) {
            try fetcher.fetch(Source(name: "x", kind: .git(url: "-oProxyCommand=touch/tmp/pwned", ref: nil)))
        }
        #expect(throws: SourceError.self) {
            try fetcher.fetch(Source(name: "x", kind: .git(url: "https://github.com/foo/bar", ref: "--upload-pack=touch/tmp/pwned")))
        }
    }
}
