import Foundation
import Testing
@testable import KittymgrCore

/// kittymgr must operate on the resolved kitty config directory no matter where
/// the process was launched from. The one intentional exception: relative paths
/// the user types (`--from <path>`, `snippet add --from`) resolve against the
/// cwd, like any CLI argument.
/// These tests are serialized because the CLI reads process-wide cwd and env.
@Suite(.serialized)
struct CLIWorkingDirectoryTests {
    private let fm = FileManager.default

    @Test func commandsOperateOnConfigDirRegardlessOfCwd() throws {
        let base = fm.temporaryDirectory.appendingPathComponent("kittymgr-cwd-\(UUID().uuidString)")
        let configDir = base.appendingPathComponent("kitty-config")
        let unrelatedCwd = base.appendingPathComponent("unrelated-cwd")
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: unrelatedCwd, withIntermediateDirectories: true)

        // Point the CLI at the config dir and run it from an unrelated cwd, as a
        // user would from any shell location.
        let previousEnv = ProcessInfo.processInfo.environment["KITTY_CONFIG_DIRECTORY"]
        setenv("KITTY_CONFIG_DIRECTORY", configDir.path, 1)
        let previousCwd = fm.currentDirectoryPath
        #expect(fm.changeCurrentDirectoryPath(unrelatedCwd.path))
        // The temp tree is intentionally not deleted: concurrently running tests
        // spawn subprocesses that may inherit this cwd, and removing a live
        // process's working directory breaks it (git: "unable to read current
        // working directory"). Like every other test dir, it lives under the
        // OS-purged temporary directory.
        defer {
            _ = fm.changeCurrentDirectoryPath(previousCwd)
            if let previousEnv {
                setenv("KITTY_CONFIG_DIRECTORY", previousEnv, 1)
            } else {
                unsetenv("KITTY_CONFIG_DIRECTORY")
            }
        }

        #expect(KittymgrCLI.run(["init"]) == 0)
        #expect(KittymgrCLI.run(["create", "work"]) == 0)
        #expect(KittymgrCLI.run(["switch", "work"]) == 0)
        #expect(KittymgrCLI.run(["current"]) == 0)
        #expect(KittymgrCLI.run(["list"]) == 0)

        // Every artifact landed inside the config dir.
        #expect(fm.fileExists(atPath: configDir.appendingPathComponent("kitty.conf").path))
        #expect(fm.fileExists(atPath: configDir.appendingPathComponent("kittymgr/profiles/work").path))
        #expect(fm.fileExists(atPath: configDir.appendingPathComponent("kittymgr/active.conf").path))
        let conf = try String(contentsOf: configDir.appendingPathComponent("kitty.conf"), encoding: .utf8)
        #expect(conf.contains("include kittymgr/active.conf"))

        // The launch directory stayed empty and the cwd itself never moved.
        #expect(try fm.contentsOfDirectory(atPath: unrelatedCwd.path).isEmpty)
        #expect(URL(fileURLWithPath: fm.currentDirectoryPath).resolvingSymlinksInPath().path
            == unrelatedCwd.resolvingSymlinksInPath().path)
    }

    @Test func noArgumentsNonInteractiveExitsTwoWithoutLaunchingUI() throws {
        let configDir = fm.temporaryDirectory.appendingPathComponent("kittymgr-noargs-nontty-\(UUID().uuidString)")
        try fm.createDirectory(at: configDir.appendingPathComponent("managed"), withIntermediateDirectories: true)

        var launched = false
        let status = withKittyConfigDirectory(configDir) {
            KittymgrCLI.run(
                [],
                isInteractive: { false },
                launchUI: { _ in launched = true }
            )
        }

        #expect(status == 2)
        #expect(launched == false)
        #expect(fm.fileExists(atPath: configDir.appendingPathComponent("kittymgr").path) == false)
    }

    @Test func noArgumentsInteractiveLaunchesUIEntrypoint() throws {
        let configDir = fm.temporaryDirectory.appendingPathComponent("kittymgr-noargs-tty-\(UUID().uuidString)")
        var launchedConfigDir: ConfigDir?

        let status = withKittyConfigDirectory(configDir) {
            KittymgrCLI.run(
                [],
                isInteractive: { true },
                launchUI: { dir in launchedConfigDir = dir }
            )
        }

        #expect(status == 0)
        #expect(launchedConfigDir == ConfigDir(url: configDir.standardizedFileURL))
        #expect(fm.fileExists(atPath: configDir.path) == false)
    }

    @Test func noArgumentsDryRunInteractiveUsesUIDryRunShortcut() throws {
        let configDir = fm.temporaryDirectory.appendingPathComponent("kittymgr-noargs-dryrun-\(UUID().uuidString)")
        var launched = false

        let status = withKittyConfigDirectory(configDir) {
            KittymgrCLI.run(
                ["--dry-run"],
                isInteractive: { true },
                launchUI: { _ in launched = true }
            )
        }

        #expect(status == 0)
        #expect(launched == false)
        #expect(fm.fileExists(atPath: configDir.path) == false)
    }

    private func withKittyConfigDirectory<T>(_ configDir: URL, _ body: () throws -> T) rethrows -> T {
        let previousEnv = ProcessInfo.processInfo.environment["KITTY_CONFIG_DIRECTORY"]
        setenv("KITTY_CONFIG_DIRECTORY", configDir.path, 1)
        defer {
            if let previousEnv {
                setenv("KITTY_CONFIG_DIRECTORY", previousEnv, 1)
            } else {
                unsetenv("KITTY_CONFIG_DIRECTORY")
            }
        }
        return try body()
    }
}

struct CLIVersionTests {
    @Test func versionConstantIsSemver() {
        let parts = Kittymgr.version.split(separator: ".", omittingEmptySubsequences: false)
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) })
    }

    @Test func versionFlagExitsZero() {
        #expect(KittymgrCLI.run(["--version"]) == 0)
        #expect(KittymgrCLI.run(["-V"]) == 0)
    }

    @Test func helpFlagExitsZero() {
        #expect(KittymgrCLI.run(["--help"]) == 0)
        #expect(KittymgrCLI.run(["-h"]) == 0)
    }
}
