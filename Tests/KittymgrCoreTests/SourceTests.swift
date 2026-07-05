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
        // A stubbed downloader exercises the write/checksum path deterministically,
        // no network.
        let cache = tempDir()
        let fetcher = DefaultSourceFetcher(cacheDir: cache) { _ in
            Data("background #282828\n".utf8)
        }
        let result = try fetcher.fetch(Source(name: "u", kind: .url("https://example.com/theme.conf")))

        #expect(result.checksum != nil)
        let downloaded = try fm.contentsOfDirectory(at: result.root, includingPropertiesForKeys: nil)
        #expect(downloaded.count == 1)
        #expect(downloaded[0].lastPathComponent == "theme.conf")
        #expect((try? String(contentsOf: downloaded[0], encoding: .utf8)) == "background #282828\n")
    }

    @Test func fetchURLRejectsNonHTTPSchemes() {
        // The default downloader refuses non-http(s) schemes before any I/O, so
        // this runs the real policy with no network.
        let fetcher = DefaultSourceFetcher(cacheDir: tempDir())
        for bad in ["file:///etc/passwd", "ftp://host/x", "data:text/plain,hi"] {
            do {
                _ = try fetcher.fetch(Source(name: "x", kind: .url(bad)))
                Issue.record("expected fetch of \(bad) to throw")
            } catch {
                #expect("\(error)".contains("scheme"), "unexpected error for \(bad): \(error)")
            }
        }
    }

    @Test func fetchURLSurfacesDownloaderDetail() {
        let fetcher = DefaultSourceFetcher(cacheDir: tempDir()) { _ in
            throw URLDownloadError.timeout(seconds: 120)
        }
        do {
            _ = try fetcher.fetch(Source(name: "x", kind: .url("https://example.com/slow")))
            Issue.record("expected the downloader error to propagate")
        } catch {
            #expect("\(error)".contains("timed out after 120s"))
        }
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
