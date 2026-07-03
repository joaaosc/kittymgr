import Foundation
import Testing
@testable import KittymgrCore

struct KittenStoreTests {
    private let fm = FileManager.default

    private func makeStore() -> (KittenStore, URL) {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-kitten-\(UUID().uuidString)/kittymgr/kittens")
        return (KittenStore(root: root), root)
    }

    private func writeSource(_ content: String) throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("hello-\(UUID().uuidString).py")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func installIsolatesAndRecordsProvenance() throws {
        let (store, root) = makeStore()
        let source = try writeSource("print('hi')\n")
        let manifest = try store.install(try PluginName(validating: "hello"), from: source)

        #expect(store.exists(try PluginName(validating: "hello")))
        #expect(fm.fileExists(atPath: root.appendingPathComponent("hello/\(source.lastPathComponent)").path))
        #expect(manifest.entry == source.lastPathComponent)
        #expect(manifest.checksum != nil)
        #expect(manifest.source == source.path)
    }

    @Test func doubleInstallThrows() throws {
        let (store, _) = makeStore()
        let source = try writeSource("print('hi')\n")
        _ = try store.install(try PluginName(validating: "hello"), from: source)
        #expect(throws: KittenError.alreadyInstalled("hello")) {
            try store.install(try PluginName(validating: "hello"), from: source)
        }
    }

    @Test func removeLeavesNoResidue() throws {
        let (store, root) = makeStore()
        let source = try writeSource("print('hi')\n")
        _ = try store.install(try PluginName(validating: "hello"), from: source)
        try store.remove(try PluginName(validating: "hello"))

        #expect(store.exists(try PluginName(validating: "hello")) == false)
        #expect(fm.fileExists(atPath: root.appendingPathComponent("hello").path) == false)
    }

    @Test func removeMissingThrows() throws {
        let (store, _) = makeStore()
        #expect(throws: KittenError.notFound("ghost")) {
            try store.remove(try PluginName(validating: "ghost"))
        }
    }

    @Test func listReportsInstalledKittens() throws {
        let (store, _) = makeStore()
        _ = try store.install(try PluginName(validating: "alpha"), from: try writeSource("a\n"))
        _ = try store.install(try PluginName(validating: "beta"), from: try writeSource("b\n"))
        #expect(store.list().map(\.name) == ["alpha", "beta"])
    }
}

struct KittenCommandTests {
    private let fm = FileManager.default

    private func makeConfigDir() throws -> ConfigDir {
        let root = fm.temporaryDirectory.appendingPathComponent("kittymgr-kittencmd-\(UUID().uuidString)")
        let dir = ConfigDir(url: root)
        try fm.createDirectory(at: dir.managedDir, withIntermediateDirectories: true)
        return dir
    }

    private func writeSource(_ content: String) throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("k-\(UUID().uuidString).sh")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func installRecordsAuditSnapshot() throws {
        let dir = try makeConfigDir()
        let source = try writeSource("echo hi\n")

        try KittenCommand(action: .install(name: "hello", source: source.path), configDir: dir)
            .run(log: { _ in })

        #expect(KittenStore(root: dir.kittensDir).exists(try PluginName(validating: "hello")))
        // A history entry was recorded for the install.
        let snapshots = SnapshotStore(configDir: dir).list()
        #expect(snapshots.contains { $0.label == "kitten-install-hello" })
    }

    @Test func dryRunInstallWritesNothing() throws {
        let dir = try makeConfigDir()
        let source = try writeSource("echo hi\n")

        var out: [String] = []
        try KittenCommand(action: .install(name: "hello", source: source.path), configDir: dir, dryRun: true)
            .run { out.append($0) }

        #expect(out.joined(separator: "\n").contains("[dry-run]"))
        #expect(KittenStore(root: dir.kittensDir).exists(try PluginName(validating: "hello")) == false)
        #expect(SnapshotStore(configDir: dir).list().isEmpty)
    }

    @Test func installMissingSourceThrows() throws {
        let dir = try makeConfigDir()
        #expect(throws: KittenError.self) {
            try KittenCommand(action: .install(name: "hello", source: "/nope/missing.sh"), configDir: dir)
                .run(log: { _ in })
        }
    }
}
